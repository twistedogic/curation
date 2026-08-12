## Why

`curation` has a running, observable server (the archived `add-server` change:
config, lifecycle, `/healthz`, auth gate, logging, `/metrics`) but no content
processing yet. Before any source is fetched, any item is labeled by `pi`, or
any EPUB is built, there must be the deterministic transform that turns raw
items into a noise-free, tagged, capped set. That pipeline is the pure,
reproducible, unit-testable core of US-003, and it is the smallest slice that
every later content change — feed/web fetching (US-002/008), longevity
evaluation (US-009), storage (FR-6), and EPUB/download (US-004) — composes
onto. Landing it now also retires no risk prematurely: the genuine tech risk
(RSS/Atom XML parsing, intent §7) belongs with the fetcher and stays out of
this cut.

## What Changes

- Add the **item model**: an input `Item` record (title, url, summary/body,
  date, source) and a `CuratedItem` carrying the same fields plus the set of
  tags the pipeline assigned. Plain value records, no I/O.
- Add the **deterministic curation pipeline**, a pure function of `(items,
  rules) → curated items` applying, in order: **normalize → dedupe → filter
  (include/exclude) → tag → cap**. Identical inputs produce identical output;
  no time, randomness, or I/O.
- Add **URL/title normalization and deduplication**: conservative URL
  normalization (lowercase scheme/host, drop fragment, drop trailing slash) and
  a dedupe key of normalized URL, falling back to a normalized-title hash when
  a URL is absent. First occurrence survives; order is preserved.
- Add **filter rules** (include/exclude, case-insensitive substring match on
  title and/or URL) and **tag rules** (assign one or more tags by the same
  kind of match).
- Add a per-run **cap** (max items) that bounds output, preserving input order.
- Extend the JSON **config** with `filter_rules`, `tag_rules`, and `cap`. The
  server's existing loader already ignores unknown fields, so loading behavior
  is unchanged — this change only adds recognized fields.
- Everything is `stdlib`-only (`std.json`, `std.crypto.hash.sha2`, `std.mem`,
  `std.testing`); no new dependency. Every pipeline stage has a runnable
  self-check, and `zig build test` stays green.

## Capabilities

### New Capabilities
- `curation`: The deterministic curation engine — the item model and the pure
  normalize/dedupe/filter/tag/cap pipeline plus its rule configuration. This is
  the transform that fetching, the `pi` longevity evaluator, storage, and the
  EPUB/download path all feed through in later changes. It owns no I/O and no
  scheduling; it is a pure function of configured rules and input items.

### Modified Capabilities
<!-- None. Config loading behavior (server capability) is unchanged: the loader
already ignores unknown fields, so adding recognized rule fields needs no
spec-level change to `server`. -->

## Impact

- **Code:** new `src/` modules for the item model and pipeline (e.g.
  `src/item.zig`, `src/curation.zig`); a small rule-config extension to
  `src/config.zig` (new fields, decoded by the existing `std.json` loader).
  No existing behavior changes; the server still serves the placeholder `/`.
- **Config:** introduces optional `filter_rules`, `tag_rules`, and `cap` fields
  in the same `config.json`; absent fields take documented defaults
  (no rules ⇒ everything passes; no cap ⇒ unbounded).
- **Dependencies:** none added — Zig 0.16 stdlib only.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the new
  self-checks.
