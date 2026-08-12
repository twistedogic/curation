## Why

`curation` has a running, observable server (`server` capability) and a pure,
deterministic curation pipeline (`curation` capability: normalize/dedupe/
filter/tag/cap) — but nothing yet acquires the `Item` records the pipeline
consumes. `.see/intent.md` calls out one "genuine tech risk — decide early":
RSS/Atom XML parsing, because Zig stdlib has no XML parser (§7). This change
lands the smallest slice that retires that risk: feed acquisition. It fetches
an RSS or Atom feed over `std.http.Client` and extracts `Item` records through
a tiny tolerant parser, producing exactly the values the existing pipeline
already runs on. It deliberately defers web rendering via Lightpanda (US-008),
storage (FR-6), longevity evaluation (US-009), EPUB/download (US-004), and the
daily job/scheduler (US-002) — each of which composes onto this layer.

## What Changes

- Add a **feed fetcher** that `GET`s a feed URL with `std.http.Client`, a
  bounded timeout, and a `User-Agent`; returns the body bytes on 2xx and an
  error otherwise. A pure I/O boundary, no parsing.
- Add a **pure, I/O-free feed parser** that extracts `Item` records (title,
  url, body, date, source) from RSS 2.0/RDF and Atom feeds, deterministic for
  identical bytes.
- Add **tolerant field extraction**: XML entity decoding (named + numeric),
  `CDATA` unwrapping, whitespace trimming, and empty-string defaults for
  missing fields — so the existing pipeline's "empty url is a valid item"
  contract holds.
- Add a **per-source acquisition step** composing fetch → parse that returns
  items or an error per source, so a later caller can skip/log one bad source
  without aborting the rest (intent: "one bad source never breaks a run").
- Everything is stdlib-only (`std.http.Client`, `std.mem`, `std.testing`); no
  in-binary dependency. The parser is fully exercised by self-checks on
  embedded synthetic RSS and Atom bytes, with no live network in tests.

## Capabilities

### New Capabilities
- `sources`: Acquire items from configured sources — fetch a feed over HTTP and
  extract item records via a tolerant parser, producing the values the
  `curation` pipeline consumes. This change implements feed sources (RSS/Atom);
  web-content sources via Lightpanda are added later.

### Modified Capabilities
<!-- None. The parser produces items matching the existing `curation` item
model (title, url, body, date, source); it composes onto the pipeline but
changes no `curation` or `server` requirement. There is no config or endpoint
change — reading configured source URLs belongs to the daily-job change
(US-002). -->

## Impact

- **Code:** new `src/` modules for fetching and parsing (e.g. `src/fetch.zig`,
  `src/feed.zig`); `main.zig` registers them in the comptime test-import block.
  No existing module changes.
- **Config:** none — the fetch/parse functions take explicit arguments (URL,
  bytes, source name). Reading configured source URLs is deferred to the
  daily-job change.
- **Dependencies:** none added — Zig 0.16 stdlib only. The XML-parsing risk is
  resolved by a hand-written tolerant parser, not a vendored library, per
  intent §2/§7.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the new
  self-checks.
