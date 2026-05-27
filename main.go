package main

import (
	"context"
	"embed"
	"encoding/xml"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/twistedogic/curation/internal/feed"
	"github.com/twistedogic/curation/internal/opml"
	"github.com/twistedogic/curation/internal/scraper"
	"github.com/twistedogic/curation/internal/server"
	"github.com/twistedogic/curation/internal/store"
)

//go:embed awesome-rss-feeds/countries
//go:embed awesome-rss-feeds/recommended
var embeddedFeeds embed.FS

func main() {
	if err := run(os.Args); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: curation <command>\ncommands: fetch, scrape")
	}
	switch args[1] {
	case "fetch":
		return fetchCmd(args[2:])
	case "scrape":
		return scrapeCmd(args[2:])
	case "list-feeds":
		return listFeedsCmd(args[2:])
	case "serve":
		return serveCmd(args[2:])
	case "query":
		return queryCmd(args[2:])
	default:
		return fmt.Errorf("unknown command: %s\nusage: curation <fetch|scrape|list-feeds|serve|query>", args[1])
	}
}

func fetchCmd(args []string) error {
	fs := flag.NewFlagSet("fetch", flag.ContinueOnError)
	var opmlPath, topicsStr, output, dbPath string
	var limit int
	fs.StringVar(&opmlPath, "opml", "", "Path to OPML file")
	fs.StringVar(&topicsStr, "topics", "", "Comma-separated topic keywords")
	fs.IntVar(&limit, "limit", 10, "Max articles per feed")
	fs.StringVar(&output, "output", "console", "Output format: console, json, markdown")
	fs.StringVar(&dbPath, "db", "", "Path to DuckDB file for persistence (optional)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if opmlPath == "" || topicsStr == "" {
		return fmt.Errorf("--opml and --topics are required")
	}

	topics := parseTopics(topicsStr)

	parser := opml.New()
	feeds, err := parser.Parse(opmlPath)
	if err != nil {
		return fmt.Errorf("failed to parse OPML: %w", err)
	}
	if len(feeds) == 0 {
		return fmt.Errorf("no feeds found in OPML")
	}

	fetcher := feed.New(feed.DefaultConfig())
	articleScraper := scraper.New(scraper.DefaultConfig())

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		cancel()
	}()

	var allItems []feed.Item
	for _, f := range feeds {
		items, err := fetcher.Fetch(ctx, f.URL, f.Name, topics, limit)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to fetch %s: %v\n", f.Name, err)
		}
		allItems = append(allItems, items...)
		time.Sleep(1 * time.Second)
		if ctx.Err() != nil {
			break
		}
	}

	scrapedContent := make(map[string]store.ScrapedContent)
	for i := range allItems {
		if allItems[i].URL != "" && ctx.Err() == nil {
			body, err := articleScraper.Scrape(ctx, allItems[i].URL)
			if err == nil && body != "" {
				sc := store.ScrapedContent{
					Description: allItems[i].Description,
					Body:        body,
				}
				scrapedContent[allItems[i].URL] = sc
				if dbPath == "" {
					allItems[i].Description = truncate(body, 500)
				} else {
					allItems[i].Description = body
				}
			}
			time.Sleep(500 * time.Millisecond)
		}
	}

	if dbPath != "" {
		st, err := store.Open(dbPath)
		if err != nil {
			return fmt.Errorf("open db: %w", err)
		}
		defer st.Close()
		if err := st.Save(allItems, scrapedContent); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to save to db: %v\n", err)
		}
	}

	switch output {
	case "json":
		return feed.FormatJSON(os.Stdout, allItems)
	case "markdown":
		return feed.FormatMarkdown(os.Stdout, allItems)
	default:
		return feed.FormatConsole(os.Stdout, allItems)
	}
}

func scrapeCmd(args []string) error {
	fs := flag.NewFlagSet("scrape", flag.ContinueOnError)
	var url string
	fs.StringVar(&url, "url", "", "URL to scrape")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if url == "" {
		return fmt.Errorf("--url is required")
	}
	s := scraper.New(scraper.DefaultConfig())
	content, err := s.Scrape(context.Background(), url)
	if err != nil {
		return fmt.Errorf("scrape failed: %w", err)
	}
	fmt.Println(content)
	return nil
}

func listFeedsCmd(args []string) error {
	fs := flag.NewFlagSet("list-feeds", flag.ContinueOnError)
	var region string
	fs.StringVar(&region, "region", "", "Filter by region/country (e.g., Hong Kong, China, USA)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	// List available OPML files in embedded FS
	// The embed directive embeds files from feeds/awesome-rss-feeds/*
	// We walk the directory structure to find .opml files
	dirs := []string{
		"awesome-rss-feeds/countries",
		"awesome-rss-feeds/recommended",
	}

	fmt.Println("Available feeds from awesome-rss-feeds:")
	fmt.Println(strings.Repeat("-", 50))

	type feedFile struct {
		category string
		path     string
		name     string
	}

	var allFiles []feedFile

	// Walk through both top-level directories
	for _, base := range dirs {
		entries, err := embeddedFeeds.ReadDir(base)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to read %s: %v\n", base, err)
			continue
		}
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			subEntries, err := embeddedFeeds.ReadDir(base + "/" + entry.Name())
			if err != nil {
				continue
			}
			for _, sub := range subEntries {
				if sub.IsDir() {
					// Two levels deep (with_category/without_category)
					category := entry.Name() + "/" + sub.Name()
					subSubEntries, err := embeddedFeeds.ReadDir(base + "/" + entry.Name() + "/" + sub.Name())
					if err != nil {
						continue
					}
					for _, f := range subSubEntries {
						if !f.IsDir() && strings.HasSuffix(f.Name(), ".opml") {
							name := strings.TrimSuffix(f.Name(), ".opml")
							// Filter by region if specified
							if region != "" && !strings.Contains(strings.ToLower(name), strings.ToLower(region)) {
								continue
							}
							allFiles = append(allFiles, feedFile{category: category, name: name, path: base + "/" + entry.Name() + "/" + sub.Name() + "/" + f.Name()})
						}
					}
				} else if !sub.IsDir() && strings.HasSuffix(sub.Name(), ".opml") {
					name := strings.TrimSuffix(sub.Name(), ".opml")
					if region != "" && !strings.Contains(strings.ToLower(name), strings.ToLower(region)) {
						continue
					}
					allFiles = append(allFiles, feedFile{category: entry.Name(), name: name, path: base + "/" + entry.Name() + "/" + sub.Name()})
				}
			}
		}
	}

	// Group by category
	byCategory := make(map[string][]feedFile)
	for _, f := range allFiles {
		byCategory[f.category] = append(byCategory[f.category], f)
	}

	for cat, files := range byCategory {
		fmt.Printf("## %s\n", cat)
		for _, f := range files {
			fmt.Printf("  [%s]\n", f.name)
			// Read the OPML and list individual feeds
			fh, err := embeddedFeeds.Open(f.path)
			if err != nil {
				continue
			}
			data, err := io.ReadAll(fh)
			fh.Close()
			if err != nil {
				continue
			}

			var feedList opml.FeedList
			if err := xml.Unmarshal(data, &feedList); err != nil {
				continue
			}

			for _, outline := range feedList.Body.Outlines {
				if outline.XMLURL != "" {
					title := outline.Text
					if title == "" {
						title = "unnamed"
					}
					fmt.Printf("    - %s: %s\n", title, outline.XMLURL)
				}
			}
		}
		fmt.Println()
	}
	return nil
}

func parseTopics(s string) []string {
	var topics []string
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p != "" {
			topics = append(topics, p)
		}
	}
	return topics
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}

func queryCmd(args []string) error {
	fs := flag.NewFlagSet("query", flag.ContinueOnError)
	var dbPath, topicsStr, output, sinceStr, untilStr string
	var limit int
	var full bool
	fs.StringVar(&dbPath, "db", "", "Path to DuckDB file (required)")
	fs.StringVar(&topicsStr, "topics", "", "Comma-separated topic keywords")
	fs.StringVar(&sinceStr, "since", "1d", "Start of time range (e.g. 1d, 7d, 2h, 2026-05-01)")
	fs.StringVar(&untilStr, "until", "", "End of time range (default: now)")
	fs.IntVar(&limit, "limit", 50, "Max results to return")
	fs.StringVar(&output, "output", "console", "Output format: console, json, markdown")
	fs.BoolVar(&full, "full", false, "Include full scraped body in output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if dbPath == "" {
		return fmt.Errorf("--db is required")
	}

	now := time.Now()
	until := now
	if untilStr != "" {
		t, err := parseTimeArg(untilStr, now)
		if err != nil {
			return fmt.Errorf("--until: %w", err)
		}
		until = t
	}
	since, err := parseTimeArg(sinceStr, until)
	if err != nil {
		return fmt.Errorf("--since: %w", err)
	}

	st, err := store.Open(dbPath)
	if err != nil {
		return fmt.Errorf("open db: %w", err)
	}
	defer st.Close()

	opts := store.QueryOpts{
		Since:  since,
		Until:  until,
		Topics: parseTopics(topicsStr),
		Limit:  limit,
		Full:   full,
	}

	ctx := context.Background()
	items, scraped, err := st.Query(ctx, opts)
	if err != nil {
		return fmt.Errorf("query failed: %w", err)
	}

	if full {
		for i, item := range items {
			if sc, ok := scraped[item.URL]; ok {
				if sc.Body != "" {
					items[i].Description = sc.Body
				} else {
					items[i].Description = sc.Description
				}
			}
		}
	}

	switch output {
	case "json":
		return feed.FormatJSON(os.Stdout, items)
	case "markdown":
		return feed.FormatMarkdown(os.Stdout, items)
	default:
		return feed.FormatConsole(os.Stdout, items)
	}
}

// parseTimeArg parses a relative duration (1d, 7d, 2h, 30m) or absolute date (2006-01-02)
// and returns the corresponding time subtracted from ref (for relative) or parsed directly.
func parseTimeArg(s string, ref time.Time) (time.Time, error) {
	if len(s) > 1 {
		unit := s[len(s)-1]
		numStr := s[:len(s)-1]
		switch unit {
		case 'd', 'h', 'm':
			var n int
			if _, err := fmt.Sscanf(numStr, "%d", &n); err == nil {
				switch unit {
				case 'd':
					return ref.Add(-time.Duration(n) * 24 * time.Hour), nil
				case 'h':
					return ref.Add(-time.Duration(n) * time.Hour), nil
				case 'm':
					return ref.Add(-time.Duration(n) * time.Minute), nil
				}
			}
		}
	}
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, fmt.Errorf("unrecognized time format %q (use e.g. 1d, 7d, 2h, 30m, or 2026-05-01)", s)
	}
	return t, nil
}

func serveCmd(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	var opmlPath, topicsStr string
	var interval, port int
	fs.StringVar(&opmlPath, "opml", "", "Path to OPML file (required)")
	fs.StringVar(&topicsStr, "topics", "", "Comma-separated topic keywords (required)")
	fs.IntVar(&interval, "interval", 30, "Polling interval in minutes (default: 30)")
	fs.IntVar(&port, "port", 8080, "HTTP server port (default: 8080)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if opmlPath == "" || topicsStr == "" {
		return fmt.Errorf("--opml and --topics are required")
	}

	cfg := server.DefaultConfig()
	cfg.Port = port
	cfg.Interval = time.Duration(interval) * time.Minute
	cfg.ListenAddr = fmt.Sprintf("0.0.0.0:%d", port)

	srv := server.New(cfg)
	srv.SetOPML(opmlPath, topicsStr)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	return srv.Start(ctx)
}

