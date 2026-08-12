## Context

`curation` today comprises two archived capabilities: `server` (a running,
observable `std.http.Server` with config loading, `/healthz`, an auth gate,
logging, and `/metrics`) and `curation` (a pure, deterministic
normalize/dedupe/filter/tag/cap pipeline operating over an `Item` model of
`title`, `url`, `body`, `date`, `source`). Nothing yet produces those `Item`s
from the outside world. `.see/intent.md` fixes the source model (FR-2: feeds via
`std.http.Client`, web URLs via Lightpanda) and the pipeline's input source
(FR-3 fetch, FR-4 extract), and flags the single hardest unknown up front (§7):
"RSS/Atom XML parsing. Zig stdlib has no XML parser." The guidance is to decide
it early, starting minimal and marking the ceiling.

This change lands that decision and the feed half of source acquisition. It is
the smallest slice that is independently testable: a fetcher (I/O, returns
bytes) and a parser (pure, bytes → items), composing into one per-source
acquisition step. It feeds the existing pipeline's exact `Item` shape and
touches no other capability. Web rendering (Lightpanda), storage, longevity
evaluation, EPUB/download, and the daily scheduler are each later changes that
consume or feed this layer.

## Goals / Non-Goals

**Goals:**
- A feed fetcher `fetchFeed(allocator, client, url, user_agent, timeout) -> []u8`
  using `std.http.Client`, bounded by a timeout, returning bytes on 2xx and an
  error otherwise; no parsing.
- A pure parser `parseFeed(allocator, bytes, source) -> []Item` accepting RSS
  2.0/RDF and Atom, deterministic for identical inputs, I/O-free.
- Tolerant extraction: entity decode (named + numeric), `CDATA` unwrap,
  whitespace trim, empty-string defaults for missing fields.
- A per-source `acquireFeed(…) -> []Item | error` composing fetch → parse,
  isolating one source's failure to an error the caller can skip.

**Non-Goals:**
- Web-content rendering via Lightpanda (US-008/FR-14) — a later change that
  adds to this capability.
- Storage (FR-6 JSONL store), longevity evaluation (US-009/FR-15), EPUB
  generation and `/download` (US-004/FR-8), the daily scheduler and
  `POST /curate` (US-002/FR-7) — all later.
- Reading configured source URLs: this change's functions take explicit
  arguments; wiring `config.sources` belongs to the daily-job change.
- A general-purpose XML/HTML DOM, DTD validation, namespace handling beyond
  RSS/Atom's forgiving subset, or feed-correctness validation — parsing is
  tolerant, not strict.
- Feed auto-discovery, OPML import (intent decision #6), or pagination.
- Changing the `Item` model — this change produces the existing model unchanged.

## Decisions

### D1. Hand-written tolerant RSS/Atom parser, not a vendored XML library
Zig 0.16 stdlib has no XML parser (the stated §7 risk). Curation needs a handful
of elements per item (`title`, `link`, `description`/`summary`/`content`,
`pubDate`/`updated`/`published`) wrapped in `<item>` (RSS) or `<entry>` (Atom).
A small, format-specific scanner that locates item blocks and extracts those
elements is a few hundred lines and needs no dependency — the lazy and
intent-endorsed choice (§7 option (a): "write a tiny tolerant RSS/Atom-specific
parser (these formats are forgiving)").
- *Alternative:* vendor a minimal XML tokenizer library. Rejected — adds an
  in-binary dependency against intent §2 ("a new one must justify itself"), for
  a subset small enough to hand-parse.
- `// ponytail: RSS/Atom-subset scanner, not a general XML parser; switch to a
  vendored tokenizer if malformed/namespace-heavy feeds in the wild defeat it.`

### D2. Pure parser separated from the I/O fetcher
`parseFeed(allocator, bytes, source) -> []Item` takes bytes, not a URL — no
network, no clock, deterministic by construction. `fetchFeed` is the only I/O
boundary. This split puts the genuine risk (parsing) behind thorough hermetic
self-checks on embedded feed strings, while the fetcher — low-risk stdlib — gets
a minimal error-path self-check only.
- *Alternative:* a single fetch-and-parse function. Rejected — couples the hard,
  testable part to live network and makes deterministic testing impossible.

### D3. Tolerant extraction, leaning on the pipeline's existing guarantees
Decode the common named entities and numeric references, unwrap `CDATA`, trim
title/url. Missing fields default to the empty string rather than failing,
because the `curation` capability already treats an empty `url` as a valid item
(and dedupes by title hash then). Malformed elements are skipped per-field, not
fatal — feeds in the wild are messy, and "one bad element never aborts" mirrors
the project's "one bad source never aborts" stance.
- *Alternative:* strict validation that rejects malformed feeds. Rejected —
  hostile to real-world feeds and against the deterministic-but-tolerant
  pipeline philosophy.
- `// ponytail: entity decode covers common + numeric references, not the full
  XML entity set; extend if exotic entities appear in real feeds.`

### D4. RSS-vs-Atom dispatch by root element
Detect mode by the root: `<rss`/`<rdf:RDF` ⇒ RSS (items under `<item>`); `<feed`
⇒ Atom (items under `<entry>`). One small dispatch yields a single `parseFeed`
entry point and one `Item` model for both, so downstream code never branches on
format.
- *Alternative:* separate `parseRss`/`parseAtom`. Rejected — duplicates the
  shared extraction logic; a single entry point is simpler for callers.

### D5. Per-source acquisition as a thin compose, not a batch loop
`acquireFeed(allocator, client, source_url, source_name, …) -> []Item` calls
`fetchFeed` then `parseFeed` and returns items or an error. The multi-source
iteration (skip + log on error) belongs to the caller — the later daily-job
change — because that is where logging and the run context live. Keeping this
layer single-source keeps it trivially testable and free of scheduling/logging
concerns.
- *Alternative:* `acquireAll(sources)` that iterates and swallows errors here.
  Rejected — would force this layer to own logging/skip policy, which is the
  job's concern; a single-source primitive is more reusable.

## Risks / Trade-offs

- **[Hand-written parser mishandles messy real feeds]** → Mitigation: tolerant
  extraction (D3), per-field skip on malformed elements, and thorough
  self-checks on representative RSS 2.0, RDF, and Atom snippets; ceiling noted
  in D1 (switch to a vendored tokenizer if real feeds defeat the subset
  scanner).
- **[Entity set is incomplete]** → Mitigation: cover the common named entities
  plus numeric references; document the ceiling (D3) and extend on evidence.
- **[No live-network test of the fetcher]** → Mitigation: the parser carries
  the risk and is fully hermetic; the fetcher is thin stdlib and is covered by
  an error-path self-check (bad host → error, no crash). Live fetching is
  exercised end-to-end in the later daily-job change.
- **[Format-detection ambiguity]** → Mitigation: RSS vs Atom roots are
  unambiguous in practice; an unrecognized root yields zero items rather than a
  fatal error (a usable empty result), matching the tolerant stance.

## Migration Plan

Greenfield and additive — no migration. Deploy by: nothing changes at runtime
(the new functions are not yet wired into any request path or schedule). The
code is exercised only by `zig build test`. Rollback is `git revert`; no store,
endpoint, or config behavior changes.
