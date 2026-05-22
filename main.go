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

	"curation/internal/feed"
	"curation/internal/opml"
	"curation/internal/scraper"
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
	default:
		return fmt.Errorf("unknown command: %s\nusage: curation <fetch|scrape|list-feeds>", args[1])
	}
}

func fetchCmd(args []string) error {
	fs := flag.NewFlagSet("fetch", flag.ContinueOnError)
	var opmlPath, topicsStr, output string
	var limit int
	fs.StringVar(&opmlPath, "opml", "", "Path to OPML file")
	fs.StringVar(&topicsStr, "topics", "", "Comma-separated topic keywords")
	fs.IntVar(&limit, "limit", 10, "Max articles per feed")
	fs.StringVar(&output, "output", "console", "Output format: console, json, markdown")
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

	// Scrape article content for top items
	for i := range allItems {
		if allItems[i].URL != "" && ctx.Err() == nil {
			content, err := articleScraper.Scrape(ctx, allItems[i].URL)
			if err == nil && content != "" {
				allItems[i].Description = truncate(content, 500)
			}
			time.Sleep(500 * time.Millisecond)
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

