package opml

import (
	"encoding/xml"
	"os"
)

// Feed represents a parsed RSS feed from an OPML outline element.
type Feed struct {
	URL    string
	Name   string
	SiteURL string
}

// Parser parses OPML 2.0 files and extracts RSS feed information.
type Parser struct{}

// New creates a new OPML parser.
func New() *Parser {
	return &Parser{}
}

// Parse reads an OPML file and returns all discovered RSS feeds.
func (p *Parser) Parse(path string) ([]Feed, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var doc opmlDoc
	if err := xml.Unmarshal(data, &doc); err != nil {
		return nil, err
	}

	var feeds []Feed
	for _, outline := range doc.Body.Outlines {
		if outline.XMLURL != "" {
			feeds = append(feeds, Feed{
				URL:    outline.XMLURL,
				Name:   outline.Text,
				SiteURL: outline.HTMLURL,
			})
		}
		for _, sub := range outline.Outlines {
			if sub.XMLURL != "" {
				feeds = append(feeds, Feed{
					URL:    sub.XMLURL,
					Name:   sub.Text,
					SiteURL: sub.HTMLURL,
				})
			}
		}
	}

	return feeds, nil
}

// opmlDoc represents the structure of an OPML 2.0 document.
type opmlDoc struct {
	XMLName xml.Name `xml:"opml"`
	Version string   `xml:"version,attr"`
	Head    opmlHead `xml:"head"`
	Body    opmlBody `xml:"body"`
}

type opmlHead struct {
	Title string `xml:"title"`
}

type opmlBody struct {
	Outlines []opmlOutline `xml:"outline"`
}

type opmlOutline struct {
	XMLURL  string         `xml:"xmlUrl,attr"`
	HTMLURL string         `xml:"htmlUrl,attr"`
	Text    string         `xml:"text,attr"`
	Type    string         `xml:"type,attr"`
	Outlines []opmlOutline `xml:"outline"`
}