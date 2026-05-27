package store

import (
	"context"
	"testing"
	"time"

	"github.com/twistedogic/curation/internal/feed"
)

func tmpDB(t *testing.T) (*Store, func()) {
	t.Helper()
	path := t.TempDir() + "/test.db"

	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	return s, func() {
		s.Close()
	}
}

func TestOpenCreatesSchema(t *testing.T) {
	s, cleanup := tmpDB(t)
	defer cleanup()

	row := s.db.QueryRow(`SELECT count(*) FROM information_schema.tables WHERE table_name IN ('items','content')`)
	var count int
	if err := row.Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("expected 2 tables, got %d", count)
	}
}

func TestSaveAndQuery(t *testing.T) {
	s, cleanup := tmpDB(t)
	defer cleanup()

	now := time.Now().UTC().Truncate(time.Second)
	items := []feed.Item{
		{
			URL:        "https://example.com/go-article",
			Title:      "Go concurrency guide",
			Source:     "Test Blog",
			PubDate:    now,
			Categories: []string{"golang", "concurrency"},
		},
		{
			URL:     "https://example.com/rust-article",
			Title:   "Rust ownership explained",
			Source:  "Test Blog",
			PubDate: now,
		},
	}
	scraped := map[string]ScrapedContent{
		"https://example.com/go-article": {
			Description: "A short RSS description",
			Body:        "Full article body about goroutines...",
		},
	}

	if err := s.Save(items, scraped); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()

	// Query without topics — should return both
	got, _, err := s.Query(ctx, QueryOpts{
		Since: now.Add(-time.Minute),
		Until: now.Add(time.Minute),
		Limit: 10,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 items, got %d", len(got))
	}

	// Query with topic filter — should return only go article
	got, _, err = s.Query(ctx, QueryOpts{
		Since:  now.Add(-time.Minute),
		Until:  now.Add(time.Minute),
		Topics: []string{"go"},
		Limit:  10,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].URL != "https://example.com/go-article" {
		t.Fatalf("expected 1 go item, got %+v", got)
	}

	// Query with --full — should return scraped content
	got, sc, err := s.Query(ctx, QueryOpts{
		Since: now.Add(-time.Minute),
		Until: now.Add(time.Minute),
		Limit: 10,
		Full:  true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 items with full, got %d", len(got))
	}
	c, ok := sc["https://example.com/go-article"]
	if !ok {
		t.Fatal("expected content for go article")
	}
	if c.Body != "Full article body about goroutines..." {
		t.Fatalf("unexpected body: %q", c.Body)
	}
}

func TestUpsertByURL(t *testing.T) {
	s, cleanup := tmpDB(t)
	defer cleanup()

	now := time.Now().UTC()
	item := feed.Item{
		URL:     "https://example.com/item",
		Title:   "Original title",
		Source:  "Blog",
		PubDate: now,
	}
	if err := s.Save([]feed.Item{item}, nil); err != nil {
		t.Fatal(err)
	}

	item.Title = "Updated title"
	if err := s.Save([]feed.Item{item}, nil); err != nil {
		t.Fatal(err)
	}

	row := s.db.QueryRow(`SELECT count(*) FROM items WHERE url = ?`, item.URL)
	var count int
	if err := row.Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("expected 1 row after upsert, got %d", count)
	}

	row = s.db.QueryRow(`SELECT title FROM items WHERE url = ?`, item.URL)
	var title string
	if err := row.Scan(&title); err != nil {
		t.Fatal(err)
	}
	if title != "Updated title" {
		t.Fatalf("expected updated title, got %q", title)
	}
}

func TestQueryDefaultTimeRange(t *testing.T) {
	s, cleanup := tmpDB(t)
	defer cleanup()

	now := time.Now().UTC()
	items := []feed.Item{
		{URL: "https://a.com/1", Title: "Recent", Source: "x", PubDate: now.Add(-1 * time.Hour)},
		{URL: "https://a.com/2", Title: "Old", Source: "x", PubDate: now.Add(-48 * time.Hour)},
	}
	if err := s.Save(items, nil); err != nil {
		t.Fatal(err)
	}

	got, _, err := s.Query(context.Background(), QueryOpts{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].URL != "https://a.com/1" {
		t.Fatalf("expected only recent item, got %+v", got)
	}
}
