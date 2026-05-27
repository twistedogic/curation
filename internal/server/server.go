package server

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/twistedogic/curation/internal/feed"
	"github.com/twistedogic/curation/internal/opml"
	"github.com/twistedogic/curation/internal/scraper"
)

type Config struct {
	Port       int
	ListenAddr string
	Interval   time.Duration
}

func DefaultConfig() Config {
	return Config{
		Port:       8080,
		ListenAddr: "0.0.0.0:8080",
		Interval:   30 * time.Minute,
	}
}

type Server struct {
	cfg        Config
	opmlPath   string
	topicsStr  string
	mu         sync.RWMutex
	items      []feed.Item
}

func New(cfg Config) *Server {
	return &Server{cfg: cfg}
}

func (s *Server) SetOPML(opmlPath, topicsStr string) {
	s.opmlPath = opmlPath
	s.topicsStr = topicsStr
}

func (s *Server) Start(ctx context.Context) error {
	if err := s.poll(ctx); err != nil {
		fmt.Printf("initial poll error: %v\n", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/feed.xml", s.handleFeedXML)
	mux.HandleFunc("/feed.json", s.handleFeedJSON)
	mux.HandleFunc("/items", s.handleItems)
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/refresh", s.handleRefresh)

	srv := &http.Server{Addr: s.cfg.ListenAddr, Handler: mux}

	go func() {
		ticker := time.NewTicker(s.cfg.Interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if err := s.poll(ctx); err != nil {
					fmt.Printf("poll error: %v\n", err)
				}
			}
		}
	}()

	go func() {
		<-ctx.Done()
		shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutCtx)
	}()

	fmt.Printf("serving on %s\n", s.cfg.ListenAddr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

func (s *Server) poll(ctx context.Context) error {
	parser := opml.New()
	feeds, err := parser.Parse(s.opmlPath)
	if err != nil {
		return fmt.Errorf("parse opml: %w", err)
	}

	topics := parseTopics(s.topicsStr)
	fetcher := feed.New(feed.DefaultConfig())
	articleScraper := scraper.New(scraper.DefaultConfig())

	var items []feed.Item
	for _, f := range feeds {
		got, err := fetcher.Fetch(ctx, f.URL, f.Name, topics, 10)
		if err != nil {
			fmt.Printf("warning: fetch %s: %v\n", f.Name, err)
			continue
		}
		items = append(items, got...)
		if ctx.Err() != nil {
			break
		}
	}

	for i := range items {
		if items[i].URL != "" && ctx.Err() == nil {
			content, err := articleScraper.Scrape(ctx, items[i].URL)
			if err == nil && content != "" {
				if len(content) > 500 {
					content = content[:500] + "..."
				}
				items[i].Description = content
			}
			time.Sleep(500 * time.Millisecond)
		}
	}

	s.mu.Lock()
	s.items = items
	s.mu.Unlock()
	return nil
}

func (s *Server) handleFeedXML(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	items := s.items
	s.mu.RUnlock()

	w.Header().Set("Content-Type", "application/rss+xml")
	enc := xml.NewEncoder(w)
	enc.Indent("", "  ")
	enc.Encode(struct {
		XMLName xml.Name   `xml:"rss"`
		Version string     `xml:"version,attr"`
		Items   []feed.Item `xml:"channel>item"`
	}{Version: "2.0", Items: items})
}

func (s *Server) handleFeedJSON(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	items := s.items
	s.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(items)
}

func (s *Server) handleItems(w http.ResponseWriter, r *http.Request) {
	s.handleFeedJSON(w, r)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	count := len(s.items)
	s.mu.RUnlock()
	fmt.Fprintf(w, `{"status":"ok","items":%d}`, count)
}

func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	go s.poll(r.Context())
	fmt.Fprint(w, `{"status":"refresh triggered"}`)
}

func parseTopics(s string) []string {
	var topics []string
	for _, p := range splitComma(s) {
		if p != "" {
			topics = append(topics, p)
		}
	}
	return topics
}

func splitComma(s string) []string {
	var out []string
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ',' {
			part := trimSpace(s[start:i])
			out = append(out, part)
			start = i + 1
		}
	}
	return out
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}
