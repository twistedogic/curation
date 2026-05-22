package feed

import (
	"encoding/json"
	"fmt"
	"io"
	"time"
)

// FormatJSON outputs items as JSON to w.
func FormatJSON(w io.Writer, items []Item) error {
	type outItem struct {
		Title      string   `json:"title"`
		Source     string   `json:"source"`
		URL        string   `json:"url"`
		PubDate    string   `json:"pub_date"`
		Categories []string `json:"categories"`
		Description string  `json:"description"`
	}

	var out []outItem
	for _, item := range items {
		pubDate := ""
		if !item.PubDate.IsZero() {
			pubDate = item.PubDate.Format(time.RFC1123Z)
		}
		out = append(out, outItem{
			Title:      item.Title,
			Source:     item.Source,
			URL:        item.URL,
			PubDate:    pubDate,
			Categories: item.Categories,
			Description: truncate(item.Description, 500),
		})
	}

	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]interface{}{
		"generated": time.Now().Format(time.RFC3339),
		"count":     len(items),
		"items":     out,
	})
}

// FormatConsole outputs items as a human-readable digest to w.
func FormatConsole(w io.Writer, items []Item) error {
	if len(items) == 0 {
		fmt.Fprintln(w, "No items found.")
		return nil
	}
	fmt.Fprintf(w, "=== Curated Digest ===\nGenerated: %s\n\n", time.Now().Format("2006-01-02 15:04:05"))
	for i, item := range items {
		pubDate := ""
		if !item.PubDate.IsZero() {
			pubDate = item.PubDate.Format("Mon, 02 Jan 2006 15:04:05 -0700")
		}
		fmt.Fprintf(w, "[%d] %s\n", i+1, item.Title)
		fmt.Fprintf(w, "    Source: %s\n", item.Source)
		fmt.Fprintf(w, "    URL: %s\n", item.URL)
		if pubDate != "" {
			fmt.Fprintf(w, "    Date: %s\n", pubDate)
		}
		if len(item.Categories) > 0 {
			fmt.Fprintf(w, "    Categories: %s\n", joinCategories(item.Categories))
		}
		if item.Description != "" {
			fmt.Fprintf(w, "    Summary: %s\n", truncate(item.Description, 300))
		}
		fmt.Fprintln(w)
	}
	return nil
}

// FormatMarkdown outputs items as a markdown digest to w.
func FormatMarkdown(w io.Writer, items []Item) error {
	if len(items) == 0 {
		fmt.Fprintln(w, "_No items found._")
		return nil
	}
	fmt.Fprintf(w, "## Curated Digest\n")
	fmt.Fprintf(w, "_Generated: %s_\n\n", time.Now().Format("2006-01-02 15:04:05"))
	for i, item := range items {
		pubDate := ""
		if !item.PubDate.IsZero() {
			pubDate = item.PubDate.Format("2006-01-02 15:04")
		}
		fmt.Fprintf(w, "### %d. %s\n", i+1, item.Title)
		fmt.Fprintf(w, "- **Source:** [%s](%s)\n", item.Source, item.URL)
		if pubDate != "" {
			fmt.Fprintf(w, "- **Date:** %s\n", pubDate)
		}
		if len(item.Categories) > 0 {
			fmt.Fprintf(w, "- **Categories:** %s\n", joinCategories(item.Categories))
		}
		if item.Description != "" {
			fmt.Fprintf(w, "\n%s\n", truncate(item.Description, 500))
		}
		fmt.Fprintln(w)
	}
	return nil
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}

func joinCategories(cats []string) string {
	if len(cats) <= 3 {
		return joinStrings(cats, ", ")
	}
	return joinStrings(cats[:3], ", ") + "..."
}

func joinStrings(ss []string, sep string) string {
	if len(ss) == 0 {
		return ""
	}
	result := ss[0]
	for i := 1; i < len(ss); i++ {
		result += sep + ss[i]
	}
	return result
}