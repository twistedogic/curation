package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"curation/internal/feed"
	"curation/internal/opml"
	"curation/internal/scraper"
)

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
	default:
		return fmt.Errorf("unknown command: %s\nusage: curation <fetch|scrape>", args[1])
	}
}

func fetchCmd(args []string) error {
	fs := flag.NewFlagSet("fetch", flag.ContinueOnError)
	var opmlPath, topicsStr, output string
	var limit int
	fs.StringVar(&opmlPath, "opml", "", "Path to OPML file")
	fs.StringVar(&topicsStr, "topics", "", "Comma-separated topic keywords")
	fs.IntVar(&limit, "limit", 10, "Max articles per feed")
	fs.StringVar(&output, "output", "console", "Output format: console, json")
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