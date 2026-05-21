package feed

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

var (
	reScript  = regexp.MustCompile(`(?si)<script[^>]*>.*?</script>`)
	reStyle   = regexp.MustCompile(`(?si)<style[^>]*>.*?</style>`)
	reTag     = regexp.MustCompile(`(?si)<[^>]+>`)
	reSpace   = regexp.MustCompile(`\s+`)
)

// Config holds fetcher configuration.
type Config struct {
	Timeout time.Duration
}

// DefaultConfig returns sensible defaults.
func DefaultConfig() Config {
	return Config{Timeout: 10 * time.Second}
}

// Fetcher fetches and filters RSS/Atom feeds using stdlib only.
type Fetcher struct {
	client *http.Client
}

// New creates a new feed fetcher.
func New(cfg Config) *Fetcher {
	return &Fetcher{client: &http.Client{Timeout: cfg.Timeout, CheckRedirect: func(*http.Request, []*http.Request) error { return nil }}}
}

// Item represents a single feed item.
type Item struct {
	Title       string
	URL         string
	Source      string
	PubDate     time.Time
	Categories  []string
	Description string
}

// Fetch retrieves a feed and optionally filters by topics.
func (f *Fetcher) Fetch(ctx context.Context, feedURL, feedName string, topics []string, limit int) ([]Item, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, feedURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "curation-cli/1.0 (+https://github.com/twistedogic/curation)")

	resp, err := f.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read failed: %w", err)
	}

	var rss rssRoot
	if err := xml.Unmarshal(body, &rss); err != nil {
		return nil, fmt.Errorf("XML parse error: %w", err)
	}

	var items []Item
	for _, entry := range rss.Channel.Items {
		if limit > 0 && len(items) >= limit {
			break
		}

		if len(topics) > 0 {
			text := strings.ToLower(entry.Title + " " + stripHTML(entry.Description))
			matched := false
			for _, t := range topics {
				if strings.Contains(text, strings.ToLower(t)) {
					matched = true
					break
				}
			}
			if !matched {
				continue
			}
		}

		pubDate := time.Time{}
		if entry.PubDate != "" {
			pubDate, _ = parseDate(entry.PubDate)
		}

		items = append(items, Item{
			Title:       entry.Title,
			URL:         entry.Link,
			Source:      feedName,
			PubDate:     pubDate,
			Categories:  entry.Categories,
			Description: stripHTML(entry.Description),
		})
	}

	return items, nil
}

// --- RSS structs (root is <rss><channel>...) ---

type rssRoot struct {
	Channel channel `xml:"channel"`
}

type channel struct {
	Title string `xml:"title"`
	Items []item `xml:"item"`
}

type item struct {
	Title       string   `xml:"title"`
	Link        string   `xml:"link"`
	Description string   `xml:"description"`
	PubDate     string   `xml:"pubDate"`
	Categories  []string `xml:"category"`
}

// --- Helpers ---

func stripHTML(s string) string {
	s = reScript.ReplaceAllString(s, "")
	s = reStyle.ReplaceAllString(s, "")
	s = reTag.ReplaceAllString(s, " ")
	s = strings.ReplaceAll(s, "&amp;", "&")
	s = strings.ReplaceAll(s, "&lt;", "<")
	s = strings.ReplaceAll(s, "&gt;", ">")
	s = strings.ReplaceAll(s, "&quot;", "\"")
	s = strings.ReplaceAll(s, "&#39;", "'")
	s = strings.ReplaceAll(s, "&nbsp;", " ")
	s = strings.TrimSpace(s)
	return reSpace.ReplaceAllString(s, " ")
}

// parseDate tries multiple common date formats.
func parseDate(s string) (time.Time, bool) {
	formats := []string{
		time.RFC1123Z,
		time.RFC1123,
		time.RFC822Z,
		time.RFC822,
		"Mon, 02 Jan 2006 15:04:05 -0700",
		"2006-01-02T15:04:05Z",
		"2006-01-02 15:04:05Z",
	}
	for _, f := range formats {
		if t, err := time.Parse(f, s); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}