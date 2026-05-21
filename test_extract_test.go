package scraper

import (
	"fmt"
	"regexp"
	"strings"
)

var (
	reScript     = regexp.MustCompile(`(?si)<script[^>]*>.*?</script>`)
	reStyle      = regexp.MustCompile(`(?si)<style[^>]*>.*?</style>`)
	reNoscript   = regexp.MustCompile(`(?si)<noscript[^>]*>.*?</noscript>`)
	reTag        = regexp.MustCompile(`(?si)<[^>]+>`)
	reWhitespace = regexp.MustCompile(`\s+`)
)

func cleanText(s string) string {
	s = reTag.ReplaceAllString(s, " ")
	s = reWhitespace.ReplaceAllString(s, " ")
	s = strings.TrimSpace(s)
	return reWhitespace.ReplaceAllString(s, " ")
}

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
			fmt.Printf("DEBUG: pattern=%q matched, text=%q len=%d\n", pattern, text, len(text))
			if len(text) > 30 {
				return text
			}
		}
	}

	if m := regexp.MustCompile(`(?si)<body[^>]*>(.*?)</body>`).FindStringSubmatch(html); len(m) > 1 {
		return cleanText(m[1])
	}

	return ""
}

func main() {
	html := "<article><p>Great content here</p></article>"
	result := extractReadableContent(html)
	fmt.Printf("Result: %q\n", result)
}
