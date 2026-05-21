package scraper

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// Config holds scraper configuration.
type Config struct {
	Timeout time.Duration
}

// DefaultConfig returns sensible defaults.
func DefaultConfig() Config {
	return Config{Timeout: 10 * time.Second}
}

// Scraper fetches URLs and extracts readable content.
type Scraper struct {
	client *http.Client
}

var (
	reScript     = regexp.MustCompile(`(?si)<script[^>]*>.*?</script>`)
	reStyle      = regexp.MustCompile(`(?si)<style[^>]*>.*?</style>`)
	reNoscript   = regexp.MustCompile(`(?si)<noscript[^>]*>.*?</noscript>`)
	reTag        = regexp.MustCompile(`(?si)<[^>]+>`)
	reWhitespace = regexp.MustCompile(`\s+`)
	reMetaDesc   = regexp.MustCompile(`(?i)<meta\s+name=["']description["']\s+content=["']([^"']+)["']`)
	reOGDesc     = regexp.MustCompile(`(?i)<meta\s+property=["']og:description["']\s+content=["']([^"']+)["']`)
)

// New creates a new web scraper.
func New(cfg Config) *Scraper {
	return &Scraper{client: &http.Client{Timeout: cfg.Timeout}}
}

// Scrape fetches a URL and extracts readable content.
func (s *Scraper) Scrape(ctx context.Context, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", fmt.Errorf("bad request: %w", err)
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (curation-cli/1.0)")
	req.Header.Set("Accept", "text/html,application/xhtml+xml")

	resp, err := s.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("fetch failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	contentType := resp.Header.Get("Content-Type")
	if !strings.Contains(contentType, "html") {
		return "", fmt.Errorf("not HTML (%s)", contentType)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read failed: %w", err)
	}
	html := string(body)

	content := extractReadableContent(html)
	if content != "" {
		return content, nil
	}

	if m := reMetaDesc.FindStringSubmatch(html); len(m) > 1 {
		return strings.TrimSpace(m[1]), nil
	}
	if m := reOGDesc.FindStringSubmatch(html); len(m) > 1 {
		return strings.TrimSpace(m[1]), nil
	}

	return "", fmt.Errorf("no readable content found")
}

// extractReadableContent tries common content containers.
func extractReadableContent(html string) string {
	html = reScript.ReplaceAllString(html, "")
	html = reStyle.ReplaceAllString(html, "")
	html = reNoscript.ReplaceAllString(html, "")

	for _, pattern := range []string{
		`(?si)<article[^>]*>(.*?)</article>`,
		`(?si)<main[^>]*>(.*?)</main>`,
		`(?si)<div[^>]*class=["'][^"']*(?:content|article|post|entry)[^"']*["'][^>]*>(.*?)</div>`,
	} {
		re := regexp.MustCompile(pattern)
		if m := re.FindStringSubmatch(html); len(m) > 1 {
			text := cleanText(m[1])
			if len(text) > 10 {
				return text
			}
		}
	}

	if m := regexp.MustCompile(`(?si)<body[^>]*>(.*?)</body>`).FindStringSubmatch(html); len(m) > 1 {
		return cleanText(m[1])
	}

	return ""
}

// cleanText converts HTML to plain text.
func cleanText(s string) string {
	s = reTag.ReplaceAllString(s, " ")
	s = reWhitespace.ReplaceAllString(s, " ")
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.TrimSpace(s)
	return reWhitespace.ReplaceAllString(s, " ")
}