package scraper

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCleanText(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"<p>Hello World</p>", "Hello World"},
		{"multiple   spaces", "multiple spaces"},
		{"  trimmed  ", "trimmed"},
		{"", ""},
	}

	for _, tc := range tests {
		got := cleanText(tc.input)
		if got != tc.expected {
			t.Errorf("cleanText(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestScraperConfig(t *testing.T) {
	cfg := DefaultConfig()
	if cfg.Timeout == 0 {
		t.Error("DefaultConfig Timeout should not be zero")
	}
}

func TestHelperWriteFile(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "out.txt")
	content := "test content"
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}
	if string(data) != content {
		t.Errorf("got %q, want %q", string(data), content)
	}
}