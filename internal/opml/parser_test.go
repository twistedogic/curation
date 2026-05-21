package opml

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParser_Parse(t *testing.T) {
	// Create a temp OPML file
	tmpDir := t.TempDir()
	opmlPath := filepath.Join(tmpDir, "test.opml")
	content := `<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
<head><title>Test Feeds</title></head>
<body>
  <outline text="HKFP" xmlUrl="https://www.hongkongfp.com/feed/" htmlUrl="https://hongkongfp.com/"/>
  <outline text="SCMP" xmlUrl="https://www.scmp.com/rss.xml" htmlUrl="https://scmp.com/"/>
</body>
</opml>`
	if err := os.WriteFile(opmlPath, []byte(content), 0644); err != nil {
		t.Fatalf("write failed: %v", err)
	}

	p := New()
	feeds, err := p.Parse(opmlPath)
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	if len(feeds) != 2 {
		t.Fatalf("expected 2 feeds, got %d", len(feeds))
	}

	if feeds[0].Name != "HKFP" || feeds[0].URL != "https://www.hongkongfp.com/feed/" {
		t.Errorf("feed 0: got %+v", feeds[0])
	}
	if feeds[1].Name != "SCMP" || feeds[1].URL != "https://www.scmp.com/rss.xml" {
		t.Errorf("feed 1: got %+v", feeds[1])
	}
}

func TestParser_ParseNested(t *testing.T) {
	tmpDir := t.TempDir()
	opmlPath := filepath.Join(tmpDir, "nested.opml")
	content := `<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
<head></head>
<body>
  <outline text="HK News">
    <outline text="HKFP" xmlUrl="https://www.hongkongfp.com/feed/"/>
    <outline text="SCMP" xmlUrl="https://www.scmp.com/rss.xml"/>
  </outline>
</body>
</opml>`
	if err := os.WriteFile(opmlPath, []byte(content), 0644); err != nil {
		t.Fatalf("write failed: %v", err)
	}

	p := New()
	feeds, err := p.Parse(opmlPath)
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	if len(feeds) != 2 {
		t.Fatalf("expected 2 feeds from nested outlines, got %d", len(feeds))
	}
}

func TestParser_ParseFileNotFound(t *testing.T) {
	p := New()
	_, err := p.Parse("/nonexistent/file.opml")
	if err == nil {
		t.Error("expected error for nonexistent file")
	}
}

func TestParser_ParseInvalidXML(t *testing.T) {
	tmpDir := t.TempDir()
	opmlPath := filepath.Join(tmpDir, "invalid.opml")
	if err := os.WriteFile(opmlPath, []byte("not xml at all"), 0644); err != nil {
		t.Fatalf("write failed: %v", err)
	}

	p := New()
	_, err := p.Parse(opmlPath)
	if err == nil {
		t.Error("expected error for invalid XML")
	}
}