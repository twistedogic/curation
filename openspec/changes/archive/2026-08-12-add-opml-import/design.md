## Context

`curation` is past v1: all nine user stories (US-001 … US-009) have capabilities
and archived changes, `zig build test` is green, and the configured inputs —
feed sources, web sources, rules, schedule, retention, the `pi` invocation — are
all driven by a single JSON config file (`src/config.zig`,
`$XDG_CONFIG_HOME/curation/config.json`, overridable via `--config`/env). The
one configured input the PRD left unautomated is adding feed sources in bulk:
intent §9 Decision #6 names OPML import as a deferred follow-up, "cheap —
reuses the XML tokenizer built for RSS/Atom."

Two existing primitives make this genuinely cheap:

- `src/feed.zig::extractAttr(tag, name)` scans a start tag for a quoted attribute
  value (already used by `extractAtomLinkHref` for `<link href=...>`). An OPML
  feed outline is `<outline xmlUrl="..." title="..." text="..."/>`; `xmlUrl` and
  `title`/`text` are exactly attribute values, so the same extractor applies.
- `src/curation.zig::normalizeUrl` is the canonical "same source?" key the
  pipeline already uses for dedupe (lowercase scheme+host, drop fragment, strip
  trailing slash). The merge must consider a source "already present" by the
  *same* key, or import and pipeline would disagree on duplicates.

OPML itself is a trivial, forgiving format: a tree of `<outline>` elements where
only those carrying an `xmlUrl` are feeds; the rest (folders/categories,
`htmlUrl`-only links) are structural. We need only the feed leaves.

## Goals / Non-Goals

**Goals:**
- `curation import <opml-file>` reads an OPML file, extracts feed outlines, and
  merges them idempotently into the config's feed `sources`, then writes the
  config back atomically to its resolved path.
- Reuse the existing tolerant attribute scanner and the existing URL-normalization
  key — no new XML/OPML dependency, no second notion of "duplicate source."
- Pure, I/O-free extractor that is unit-testable in isolation (mirrors
  `src/feed.zig::parseFeed`'s shape: bytes in, `[]config.Source` out).
- A `ponytail:`-marked ceiling on every deliberate simplification.

**Non-Goals:**
- No OPML *export* (the reverse direction).
- No fetching or validation of imported feeds at import time — they are simply
  added; a later curation run fetches them and skips any that fail (per-source
  error isolation, sources spec).
- No mapping of OPML categories/folders to tags or to feed grouping. Folders are
  traversed, not represented.
- No import of `htmlUrl`-only or non-feed outlines; only `xmlUrl`-bearing
  outlines become feed sources.
- No `web_sources` import — OPML is a feed-subscription format; web-content
  sources stay hand-configured (US-008 is a different acquisition kind).
- No `--out` flag — the config path is already overridable via `--config`/env,
  and writing back to that path is the natural "merge into my config" behavior.

## Decisions

**D1. New capability `opml-import`, not an extension of `sources`.**
The `sources` capability owns *acquisition* (fetching, parsing, web rendering).
Import is a *configured-input* concern: a one-shot CLI command that mutates the
config file, performs no acquisition, and is over before `serve`'s pipeline
runs. Keeping them separate matches the existing one-capability-per-concern
shape (the longevity evaluator, storage, and download capabilities each own one
job) and keeps the `sources` spec focused on fetch/parse semantics. The new
subcommand is dispatched alongside `serve` in the CLI entry; that wiring is
implementation, not a `server` requirement change (server already shows usage
for unknown commands).

**D2. Reuse `feed.zig::extractAttr` for outline attributes.**
An OPML feed outline is a self-closing `<outline .../>` (or paired) start tag
whose feed identity lives in `xmlUrl` and whose display name lives in `title`
(falling back to `text`). `extractAttr` already extracts a quoted attribute from
a tag slice. The extractor scans for `<outline` start tags (the same tolerant
`indexOfScalar('<')` → next `'>'` walk used by `extractAtomLinkHref`), slices the
tag, and pulls `xmlUrl`/`title`/`text` with `extractAttr`. We promote
`extractAttr` to `pub` in `src/feed.zig` (it is already a pure, allocation-free
leaf helper) rather than duplicate it. *Alternative considered:* a hand-rolled
OPML regex — rejected, Zig has no regex in stdlib and the attribute scanner
already exists.

**D3. Reuse the pipeline's URL-normalization key for the merge dedupe.**
A source is "already present" iff its normalized url matches an existing
source's normalized url, using the *same* `normalizeUrl` the curation pipeline
uses for item dedupe. This guarantees import and pipeline agree on what counts
as a duplicate. Concretely, promote the dedupe-key step (normalize url; empty url
is not dedupable and is kept verbatim) to a shared `pub` helper and call it from
both the pipeline and the import merge. *Alternative considered:* a simpler
exact-string url compare — rejected, it would let `https://X/` and
`https://x/#f` both import and then collapse in the pipeline, two notions of
"duplicate."

**D4. Merge = append-in-document-order, dedupe against existing + within-batch.**
Existing `sources` are preserved in place and order. Each extracted outline is
appended iff its normalized url is not already in (existing ∪ newly-added). This
makes the command idempotent: re-importing the same OPML is a no-op on the
`sources` array. Name collisions on different urls are allowed (OPML permits
duplicate titles); dedupe is strictly by normalized url.

**D5. Atomic config rewrite via temp + rename.**
The merge produces a full in-memory config (`Config.load` → mutate `sources` →
serialize with `std.json`), written to a sibling temporary file then atomically
renamed over the resolved config path (same crash-safe pattern the storage
retention prune uses for its JSONL rewrite). A crash mid-write leaves the old
config intact. *Alternative considered:* in-place append — rejected, JSON is not
append-only and a torn write would corrupt the whole config.

**D6. Name resolution: `title`, else `text`, else the url.**
OPML outlines name themselves via `title` or `text` (often both). We take
`title` first, then `text`, and if neither is present use the url so the source
is never nameless. No entity decoding beyond what `extractAttr`'s raw slice
yields is required for v1 — OPML feed titles are plain text in practice.
`// ponytail: no HTML-entity decoding of OPML titles; revisit if a real
exporter emits encoded titles.`

## Risks / Trade-offs

- **Outline scanner is RSS/Atom-grade tolerant, not a real XML parser.** Like
  `src/feed.zig`, the extractor is a forgiving substring scanner; a wildly
  malformed OPML could mis-slice a tag. → Mitigation: it is read-only on the
  *config* (the only write is the merged config), skipped bad outlines never
  abort the run, and the extractor has unit tests on real OPML 1.0/2.0 samples.
  Marked with a `ponytail:` ceiling.
- **Config fields other than `sources` are round-tripped through `std.json`.** A
  rewrite re-serializes the whole config; if the loaded config carried a field
  the `Config` struct does not model, it is dropped on rewrite. → Mitigation:
  `Config` already ignores unknown fields on *load* (server spec scenario
  "unknown fields are ignored"), so this is consistent with existing behavior,
  not a regression. The PRD's config is fully modeled. Acceptable.
- **Promoting two `pub` helpers (`extractAttr`, the dedupe-key) widens the
  module surface.** → Mitigation: both are already pure leaf functions; making
  them `pub` only exposes what is reused, no new abstraction.
- **No feed validation at import.** A typo'd `xmlUrl` is imported as-is. →
  Mitigation: by design (Non-Goal); the next curation run's per-source error
  isolation logs and skips it without breaking the run.
