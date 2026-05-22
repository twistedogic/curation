package feed

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestFormatConsole(t *testing.T) {
	items := []Item{
		{
			Title:       "Test Article",
			URL:         "https://example.com/article",
			Source:      "TestFeed",
			PubDate:     time.Date(2026, 5, 21, 10, 0, 0, 0, time.UTC),
			Categories:  []string{"Tech", "AI"},
			Description: "This is a test article description.",
		},
	}

	// Just verify it doesn't panic
	err := FormatConsole(&strings.Builder{}, items)
	if err != nil {
		t.Errorf("FormatConsole failed: %v", err)
	}
}

func TestFormatConsoleEmpty(t *testing.T) {
	err := FormatConsole(&strings.Builder{}, []Item{})
	if err != nil {
		t.Errorf("FormatConsole empty failed: %v", err)
	}
}

func TestFormatJSON(t *testing.T) {
	items := []Item{
		{
			Title:       "Test Article",
			URL:         "https://example.com/article",
			Source:      "TestFeed",
			PubDate:     time.Date(2026, 5, 21, 10, 0, 0, 0, time.UTC),
			Categories:  []string{"Tech", "AI"},
			Description: "This is a test article description.",
		},
	}

	var sb strings.Builder
	err := FormatJSON(&sb, items)
	if err != nil {
		t.Errorf("FormatJSON failed: %v", err)
	}

	out := sb.String()
	if !strings.Contains(out, "Test Article") {
		t.Errorf("JSON missing title field: %s", out)
	}
	if !strings.Contains(out, "count") || !strings.Contains(out, "1") {
		t.Errorf("JSON missing count: %s", out)
	}
}

func TestFormatJSONEmpty(t *testing.T) {
	var sb strings.Builder
	err := FormatJSON(&sb, []Item{})
	if err != nil {
		t.Errorf("FormatJSON empty failed: %v", err)
	}

	out := sb.String()
	if !strings.Contains(out, "count") || !strings.Contains(out, "0") {
		t.Errorf("JSON empty count wrong: %s", out)
	}
}

func TestFormatMarkdown(t *testing.T) {
	items := []Item{
		{
			Title:       "Test Article",
			URL:         "https://example.com/article",
			Source:      "TestFeed",
			PubDate:     time.Date(2026, 5, 21, 10, 0, 0, 0, time.UTC),
			Categories:  []string{"Tech", "AI"},
			Description: "This is a test article description.",
		},
	}

	var sb strings.Builder
	err := FormatMarkdown(&sb, items)
	if err != nil {
		t.Errorf("FormatMarkdown failed: %v", err)
	}

	out := sb.String()
	if !strings.Contains(out, "## Curated Digest") {
		t.Errorf("Markdown missing header: %s", out)
	}
	if !strings.Contains(out, "### 1. Test Article") {
		t.Errorf("Markdown missing title: %s", out)
	}
	if !strings.Contains(out, "- **Source:** [TestFeed](https://example.com/article)") {
		t.Errorf("Markdown missing source link: %s", out)
	}
	if !strings.Contains(out, "Tech, AI") {
		t.Errorf("Markdown missing categories: %s", out)
	}
}

func TestFormatMarkdownEmpty(t *testing.T) {
	var sb strings.Builder
	err := FormatMarkdown(&sb, []Item{})
	if err != nil {
		t.Errorf("FormatMarkdown empty failed: %v", err)
	}

	out := sb.String()
	if !strings.Contains(out, "_No items found._") {
		t.Errorf("Markdown empty output wrong: %s", out)
	}
}

func TestStripHTML(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"<script>alert('x')</script>Hello", "Hello"},
		{"<p>Paragraph</p>", "Paragraph"},
		{"Hello &amp; World", "Hello & World"},
		{"multiple   spaces", "multiple spaces"},
	}

	for _, tc := range tests {
		got := stripHTML(tc.input)
		if got != tc.expected {
			t.Errorf("stripHTML(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestTruncate(t *testing.T) {
	tests := []struct {
		s        string
		max      int
		expected string
	}{
		{"short", 10, "short"},
		{"exactly10!", 10, "exactly10!"},
		{"this is longer", 10, "this is lo..."},
		{"", 5, ""},
	}

	for _, tc := range tests {
		got := truncate(tc.s, tc.max)
		if got != tc.expected {
			t.Errorf("truncate(%q, %d) = %q, want %q", tc.s, tc.max, got, tc.expected)
		}
	}
}

func TestParseDate(t *testing.T) {
	tests := []struct {
		input    string
		expected time.Time
		ok       bool
	}{
		{"Fri, 21 May 2026 10:00:00 +0000", time.Date(2026, 5, 21, 10, 0, 0, 0, time.UTC), true},
		{"2026-05-21T10:00:00Z", time.Date(2026, 5, 21, 10, 0, 0, 0, time.UTC), true},
		{"invalid date string", time.Time{}, false},
	}

	for _, tc := range tests {
		got, ok := parseDate(tc.input)
		if ok != tc.ok {
			t.Errorf("parseDate(%q) ok=%v, want %v", tc.input, ok, tc.ok)
		}
		if tc.ok && !got.Equal(tc.expected) {
			t.Errorf("parseDate(%q) = %v, want %v", tc.input, got, tc.expected)
		}
	}
}

func TestJoinCategories(t *testing.T) {
	tests := []struct {
		input    []string
		expected string
	}{
		{[]string{"Tech"}, "Tech"},
		{[]string{"Tech", "AI"}, "Tech, AI"},
		{[]string{"Tech", "AI", "ML", "Extra"}, "Tech, AI, ML..."},
	}

	for _, tc := range tests {
		got := joinCategories(tc.input)
		if got != tc.expected {
			t.Errorf("joinCategories(%v) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

// Helper for temp files in other tests
func TestHelperTempFile(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "test.json")
	if err := os.WriteFile(path, []byte(`{"test":true}`), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}
	if string(data) != `{"test":true}` {
		t.Errorf("unexpected content: %s", data)
	}
}