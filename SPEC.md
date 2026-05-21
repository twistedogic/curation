# Curation System — SPEC

## 1. Overview

**Name:** curation
**Type:** CLI tool + Picoclaw agent skill
**Summary:** Takes topic keywords + OPML feed list → fetches feeds → filters by keywords → scrapes article content → returns a curated digest. Optionally generates a new RSS feed.
**Stack:** Go (CLI), Python/bash (skill wrapper)

---

## 2. CLI Specification

### Interface

```bash
curation [global flags] [command] [command flags]
```

### Global Flags
| Flag | Default | Description |
|------|---------|-------------|
| `--opml string` | required | Path to OPML file (e.g. `feeds/opml/hk.xml`) |
| `--topics string` | required | Comma-separated topic keywords |
| `--limit int` | `10` | Max articles per feed to consider |
| `--output string` | `console` | Output format: `console`, `rss`, `json` |

### Commands

#### `fetch` — Fetch and filter feeds
```bash
curation fetch [flags]
  --opml ./hk-feeds.opml
  --topics "housing,subdivided units"
  --limit 10
  --output console
```
- Parses OPML → extracts feed URLs
- Fetches each feed
- Filters items where title/description/categories contain any keyword (case-insensitive)
- Scrapes full article for each match
- Outputs digest

#### `scrape` — Scrape a single URL
```bash
curation scrape [flags]
  --url https://example.com/article
  --output text
```
- Fetches URL → extracts readable content
- Outputs plain text

#### `serve` — HTTP server (optional, future)
```bash
curation serve [flags]
  --port 8080
  --opml ./feeds.opml
  --topics "housing"
```
- Polls feeds on a schedule → generates RSS feed at `/feed.xml`

### Output Formats

#### `console` (default)
```
=== Curated Digest: "housing,subdivided units" ===
Generated: 2026-05-21 02:30:00 HKT

[1] Kowloon Bay fire displaces residents
    Source: Hong Kong Free Press
    URL: https://www.hongkongfp.com/...
    PubDate: Wed, 20 May 2026 10:20:40 +0000
    Summary: (scraped content snippet)

---
[2] 11,000 subdivided units registered under BHU grace period
    Source: Hong Kong Free Press
    ...
```

#### `json`
```json
{
  "generated": "2026-05-21T02:30:00Z",
  "topics": ["housing", "subdivided units"],
  "items": [
    {
      "title": "...",
      "source": "Hong Kong Free Press",
      "url": "https://...",
      "pub_date": "Wed, 20 May 2026 10:20:40 +0000",
      "summary": "...",
      "content": "...",
      "categories": ["Housing", "Law & Crime"]
    }
  ]
}
```

#### `rss`
Generates a valid RSS 2.0 feed with `<item>` elements containing the curated articles.

---

## 3. Web Scraper Specification

### Requirements
- Takes any URL from a feed item
- Fetches HTML
- Extracts readable text content (removes nav, ads, footers, scripts)
- Falls back to `<meta>` description or feed item description if scraping fails
- Handles common anti-bot patterns (status codes, empty responses)

### Implementation
- Use Go's `net/http` for fetching
- Readable extraction via regex/CSS-like selectors (no heavy deps)
- No JavaScript rendering (headless browser not needed for news sites)
- Timeout: 10s per URL

### Edge Cases
| Scenario | Behavior |
|----------|----------|
| URL returns 4xx/5xx | Log warning, skip item, use feed description |
| Content empty | Use feed description as fallback |
| Non-HTML (PDF, redirect) | Log warning, skip |
| Timeout | Log warning, skip |
| Rate limited | Per-feed rate limiting: max 1 req/sec |

---

## 4. OPML Parsing

### Input
OPML 2.0 file from `plenaryapp/awesome-rss-feeds`

### Parsing Rules
- Find all `<outline type="rss">` or `<outline xmlUrl="...">` elements
- Extract `xmlUrl` attribute → feed URL
- Extract `text` or `title` attribute → feed name
- Extract `htmlUrl` attribute → source website (optional)

### Example HK Feeds (from awesome-rss-feeds)
| Feed | URL |
|------|-----|
| HKFP | https://www.hongkongfp.com/feed/ |
| SCMP | https://www.scmp.com/rssfeed/ |
| Headline Daily | https://www.hket.com/rss/ |
| The Standard | https://www.thestandard.com.hk/rss/ |

---

## 5. Agent Skill Specification

### Skill Name
`curation` — RSS feed curation skill

### Interface
The skill is invoked with:
- `topics`: string — comma-separated keywords to filter
- `opml`: string — path to local OPML (or use bundled HK OPML)
- `limit`: int — max articles (default 10)

### Behavior
1. Invokes `curation fetch` CLI with the given args
2. Parses output
3. Formats a readable digest for the user

### Bundled OPML
Include a small HK-focused OPML with 10-15 feeds as a default:
- HKFP, SCMP, Headline, The Standard, RTHK, CDT, Xinhua HK, Ming Pao, Oriental Daily, Sing Tao

---

## 6. File Structure

```
projects/curation-system/
├── SPEC.md
├── cmd/
│   └── curation/
│       ├── main.go          # CLI entry point
│       └── fetch.go         # fetch command
│       └── scrape.go       # scrape command
├── internal/
│   ├── opml/
│   │   └── parser.go       # OPML parsing
│   ├── feed/
│   │   └── fetcher.go      # RSS feed fetching + filtering
│   ├── scraper/
│   │   └── scraper.go      # Web content extraction
│   └── output/
│       ├── console.go      # console formatter
│       ├── json.go         # JSON formatter
│       └── rss.go          # RSS 2.0 generator
├── feeds/
│   └── hk.opml             # Bundled HK OPML (default)
├── go.mod
├── go.sum
└── Makefile
```

---

## 7. Dependencies

Minimize dependencies. Target:
- Go stdlib only for core (`net/http`, `encoding/xml`, `regexp`)
- `github.com/mmcdole/gofeed` for RSS/Atom parsing
- No external scraping libs

---

## 8. Acceptance Criteria

- [ ] `curation fetch --opml <file> --topics "keyword"` returns filtered articles
- [ ] Each article link is scraped and content is extracted
- [ ] Output renders correctly in console, JSON, and RSS formats
- [ ] Bundled `hk.opml` works out of the box
- [ ] Agent skill invokes CLI and returns digest
- [ ] Handles errors gracefully (404, timeout, empty content)
- [ ] Builds with `go build ./cmd/curation`
- [ ] Unit tests pass with `go test ./...`

---

## 9. Out of Scope

- AI/LLM summarization (extractive only — use article text as-is or first N chars)
- On-disk storage / history
- Multi-threaded polling
- Authentication-protected feeds
- RSS feed generation as a service (future)