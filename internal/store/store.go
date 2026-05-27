package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	_ "github.com/marcboeker/go-duckdb"

	"github.com/twistedogic/curation/internal/feed"
)

const schema = `
CREATE TABLE IF NOT EXISTS items (
	url        TEXT PRIMARY KEY,
	title      TEXT,
	source     TEXT,
	pub_date   TIMESTAMPTZ,
	categories TEXT,
	fetched_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS content (
	url         TEXT PRIMARY KEY,
	description TEXT,
	body        TEXT,
	scraped_at  TIMESTAMPTZ DEFAULT now()
);
`

// ScrapedContent holds scraped article data for a single URL.
type ScrapedContent struct {
	Description string
	Body        string
}

// QueryOpts controls what store.Query returns.
type QueryOpts struct {
	Since  time.Time
	Until  time.Time
	Topics []string
	Limit  int
	Full   bool
}

// Store wraps a DuckDB connection.
type Store struct {
	db *sql.DB
}

// Open opens (or creates) a DuckDB file at path and applies the schema.
func Open(path string) (*Store, error) {
	db, err := sql.Open("duckdb", path)
	if err != nil {
		return nil, fmt.Errorf("open duckdb: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &Store{db: db}, nil
}

// Close closes the underlying database connection.
func (s *Store) Close() error {
	return s.db.Close()
}

// Save upserts feed items and their scraped content into the database.
// items is upserted first; content rows are only inserted when present in scraped.
func (s *Store) Save(items []feed.Item, scraped map[string]ScrapedContent) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()

	itemStmt, err := tx.Prepare(`
		INSERT INTO items (url, title, source, pub_date, categories, fetched_at)
		VALUES (?, ?, ?, ?, ?, now())
		ON CONFLICT (url) DO UPDATE SET
			title      = excluded.title,
			fetched_at = now()
	`)
	if err != nil {
		return fmt.Errorf("prepare items stmt: %w", err)
	}
	defer itemStmt.Close()

	contentStmt, err := tx.Prepare(`
		INSERT INTO content (url, description, body, scraped_at)
		VALUES (?, ?, ?, now())
		ON CONFLICT (url) DO UPDATE SET
			description = excluded.description,
			body        = excluded.body,
			scraped_at  = now()
	`)
	if err != nil {
		return fmt.Errorf("prepare content stmt: %w", err)
	}
	defer contentStmt.Close()

	for _, item := range items {
		pubDate := item.PubDate
		if pubDate.IsZero() {
			pubDate = time.Now()
		}
		cats := marshalCategories(item.Categories)
		if _, err := itemStmt.Exec(item.URL, item.Title, item.Source, pubDate, cats); err != nil {
			return fmt.Errorf("upsert item %s: %w", item.URL, err)
		}

		if sc, ok := scraped[item.URL]; ok {
			if _, err := contentStmt.Exec(item.URL, sc.Description, sc.Body); err != nil {
				return fmt.Errorf("upsert content %s: %w", item.URL, err)
			}
		}
	}

	return tx.Commit()
}

// Query retrieves items matching the given options.
func (s *Store) Query(ctx context.Context, opts QueryOpts) ([]feed.Item, map[string]ScrapedContent, error) {
	if opts.Until.IsZero() {
		opts.Until = time.Now()
	}
	if opts.Since.IsZero() {
		opts.Since = opts.Until.Add(-24 * time.Hour)
	}
	if opts.Limit <= 0 {
		opts.Limit = 50
	}

	var (
		args      []any
		whereParts []string
	)

	args = append(args, opts.Since, opts.Until)
	whereParts = append(whereParts, "i.pub_date >= ?", "i.pub_date <= ?")

	if len(opts.Topics) > 0 {
		var topicClauses []string
		for _, t := range opts.Topics {
			pattern := "%" + strings.ToLower(t) + "%"
			topicClauses = append(topicClauses,
				"lower(i.title) LIKE ?",
				"lower(c.description) LIKE ?",
			)
			args = append(args, pattern, pattern)
		}
		whereParts = append(whereParts, "("+strings.Join(topicClauses, " OR ")+")")
	}

	selectCols := "i.url, i.title, i.source, i.pub_date, i.categories"
	joinClause := "LEFT JOIN content c ON c.url = i.url"
	if !opts.Full && len(opts.Topics) == 0 {
		joinClause = ""
	}

	query := fmt.Sprintf(
		`SELECT %s FROM items i %s WHERE %s ORDER BY i.pub_date DESC LIMIT ?`,
		selectCols,
		joinClause,
		strings.Join(whereParts, " AND "),
	)
	args = append(args, opts.Limit)

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, nil, fmt.Errorf("query items: %w", err)
	}
	defer rows.Close()

	var items []feed.Item
	var urls []string
	for rows.Next() {
		var (
			item    feed.Item
			catsStr string
		)
		if err := rows.Scan(&item.URL, &item.Title, &item.Source, &item.PubDate, &catsStr); err != nil {
			return nil, nil, fmt.Errorf("scan row: %w", err)
		}
		item.Categories = unmarshalCategories(catsStr)
		items = append(items, item)
		urls = append(urls, item.URL)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	scraped := make(map[string]ScrapedContent)
	if opts.Full && len(urls) > 0 {
		placeholders := strings.Repeat("?,", len(urls))
		placeholders = placeholders[:len(placeholders)-1]
		contentArgs := make([]any, len(urls))
		for i, u := range urls {
			contentArgs[i] = u
		}
		crows, err := s.db.QueryContext(ctx,
			`SELECT url, description, body FROM content WHERE url IN (`+placeholders+`)`,
			contentArgs...,
		)
		if err != nil {
			return nil, nil, fmt.Errorf("query content: %w", err)
		}
		defer crows.Close()
		for crows.Next() {
			var u, desc, body string
			if err := crows.Scan(&u, &desc, &body); err != nil {
				return nil, nil, fmt.Errorf("scan content: %w", err)
			}
			scraped[u] = ScrapedContent{Description: desc, Body: body}
		}
		if err := crows.Err(); err != nil {
			return nil, nil, err
		}
	}

	return items, scraped, nil
}

func marshalCategories(cats []string) string {
	if len(cats) == 0 {
		return "[]"
	}
	b, _ := json.Marshal(cats)
	return string(b)
}

func unmarshalCategories(s string) []string {
	if s == "" || s == "[]" {
		return nil
	}
	var cats []string
	_ = json.Unmarshal([]byte(s), &cats)
	return cats
}
