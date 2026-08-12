## Context

After eight archived changes, `curation` has a complete feed→digest pipeline:
the HTTP surface and config (`add-server`), the pure curation pipeline
(`add-curation-pipeline`), feed fetching + parsing (`add-feed-fetching`), the
`pi` longevity evaluator (`add-longevity-evaluator`), the append-only JSONL
store (`add-storage`), the token codec + EPUB builder + resolver and
`GET /download` (`add-epub-download`), the embedded download page
(`add-download-ui`), and the end-to-end daily job that wires them together
(`add-curation-job`). The job acquires configured feed sources, runs the
pipeline, classifies each survivor via `pi`, and stores survivors split into the
`news`/`knowledge` streams.

What is missing is the **second source kind** the intent calls for. `.see/intent.md`
§1 shows two source types in the core data flow — "sources (feeds via
`std.http.Client`; web URLs via Lightpanda)" — and US-008 / FR-14 / Decision #3
fix their contract: web-content URLs are rendered out-of-process by
`lightpanda fetch --dump <markdown|html> <url>`, the rendered output **is** the
item body (Lightpanda's `--dump` is the readability layer, so no in-binary
extractor), and a missing binary or failed render skips that source without
aborting the run. Every prior change deferred this: the `sources` spec says
"Web-content sources … are added in a later change," and `add-curation-job`
design D2 explicitly left a forward-compatible seam ("US-008 can extend the
source model later … a sibling `web_sources` list"). So today `curation-job.run`
takes only feed sources and one feed-shaped `AcquireFn`, and `fetch.zig` only
knows `std.http.Client`. A configured web page is simply never acquired.

This change adds the web acquisition path and wires it into the run, along the
forward-compatible path D2 already chose. It depends only on already-built,
unchanged capabilities: web items are plain `Item` values, they flow through the
unchanged pure pipeline (dedupe/filter/tag/cap), the unchanged longevity
classifier, and the unchanged store. The only genuinely new thing is one
subprocess-rendering acquisition function and the config/job plumbing to call it.

## Goals / Non-Goals

**Goals:**
- A library-callable `sources`-capability `acquireWeb` that renders one
  web-content URL via the Lightpanda headless browser out-of-process
  (`<lightpanda.path> fetch --dump <lightpanda.dump_format> <url>`), captures
  stdout, and returns **exactly one** `Item` (body = captured output verbatim,
  url = source URL, source/title = source name). Failure-tolerant: a missing
  binary, non-zero exit, timeout, or empty stdout is an error, never a crash.
- The `curation-job` run acquires configured **web sources in addition to feed
  sources** (`run`/`tryRun` gain a `web_sources` list, a Lightpanda config, and
  a `WebAcquireFn` seam), feeding the same union of items into the unchanged
  pipeline/classify/store path. Web render failures are per-source failures
  (logged + counted in `failed_sources`, run continues), exactly like feed
  fetch/parse failures.
- `web_sources` (`{name,url}`) and a `lightpanda` object (`{path, dump_format}`)
  in the server-owned config schema, defaulted when absent, deep-owned like the
  other slice fields.
- `zig build test` green.

**Non-Goals:**
- A persistent `lightpanda serve` CDP/WebSocket session (Decision #3 ceiling) —
  one subprocess spawn per URL this slice; revisit only if URL volume makes
  spawn overhead matter.
- Deriving a real `<title>`/first-heading for web items — `title` is the source
  name (the body is the content). Refine if longevity-classification or
  EPUB-heading quality needs it (D2).
- A new EPUB kind or kind-discrimination for web sources — web items split into
  `news`/`knowledge` by the **existing** longevity evaluator, identical to feed
  items.
- Age-based retention / prune (FR-16) — a separate slice; the store still grows
  until then.
- Extended curation/source/`pi`/render Prometheus metrics (US-006) — a separate
  slice; web failures are already surfaced as `failed_sources` in the run
  summary and the structured `curation.source_failed` log line.
- Per-URL render retries/backoff or a render cache — Lightpanda is invoked once
  per web source per run; the longevity cache already avoids re-spending `pi`
  on the same body.

## Decisions

### D1. The `sources` capability owns web acquisition in a new `render.zig`; `server` owns the config fields and the call-site wiring
The web render is an acquisition I/O boundary — the sibling of `fetch.zig`'s
HTTP fetch+parse path — so it lives in the `sources` capability alongside
`fetch.zig` (HTTP) and `feed.zig` (parse), in a new `src/render.zig` that owns
only the Lightpanda subprocess invocation. This mirrors the established
granularity where each prior change kept a distinct concern in a focused module
(`store.zig`, `download.zig`, `fetch.zig`), rather than overloading `fetch.zig`
("HTTP feed fetcher") with subprocess spawning. Config is "the JSON file loaded
by the server capability" per every prior spec, so `web_sources`/`lightpanda`
are added to `config.zig`. The two `tryRun` call sites are runtime wiring the
`server` already owns (`POST /curate` handler + the daily scheduler).
- *Alternative:* overload `fetch.zig` with `acquireWeb`. Rejected — `fetch.zig`
  is explicitly the HTTP client wrapper; a child-process renderer is a different
  I/O kind, and mixing them obscures both at 3am. One focused module per
  acquisition kind matches the rest of the codebase.
- *Alternative:* make web rendering its own top-level capability. Rejected — it
  is an acquisition path, not a new business domain; it returns the same `Item`
  the feed path returns and has no independent contract worth a capability
  boundary.

### D2. One item per web source; `title` = `source` = the source name; `body` = rendered output verbatim
A web-content source is a single page, so `acquireWeb` returns exactly one
`Item`. Lightpanda's `--dump markdown` (or `html`) output **is** the body — no
readability step (FR-14: "the `--dump markdown` is the readability layer"). A
web page has no structured title field curation can trust; the source `name` the
operator chose is a stable, human-meaningful title and dedupes by URL anyway
(the source URL is unique per source). The longevity classifier and the EPUB
both operate on title+body; source-name-as-title is good enough for v1 and keeps
the item model identical across both source kinds.
`// ponytail: web item title = source name; derive from the first markdown H1
// (or Lightpanda metadata) if classification or EPUB-heading quality needs it.`
- *Alternative:* parse the first `# ` heading out of the rendered markdown for
  the title. Rejected now — a fragile heuristic before any measured need; the
  source name is honest and stable.

### D3. Render failure = a per-source error, isolated exactly like a feed failure
A missing Lightpanda binary, a non-zero exit, a timeout, or empty stdout SHALL be
an error from `acquireWeb`, and the `curation-job` run treats it identically to a
feed fetch/parse failure: log a structured `curation.source_failed` line,
increment `failed_sources`, and continue. This is the same contract
`fetch.acquireFeed` already satisfies and the run already honors; the web path
just adds another source kind to the same isolation loop. A web failure never
crashes and never aborts the run or the storage of other sources' survivors.
- *Alternative:* cache render failures to avoid re-spawning a missing binary
  every run. Rejected — YAGNI; the spawn cost of a failing exec is negligible
  for a daily run, and the operator who installs Lightpanda wants the next run
  to "just work" without clearing a failure cache.

### D4. Extend `run`/`tryRun` with a `WebAcquireFn` seam and a `web_sources` list; acquire feeds then webs into the same union
The run already takes an injectable `AcquireFn` (production wires
`fetch.acquireFeed`; tests stub it). The web path gets a parallel
`WebAcquireFn` seam (signature differs: no `*std.http.Client`, but a Lightpanda
config, since Lightpanda does its own fetching). The run iterates feed sources
then web sources, appending every acquired item into the existing `flat_items`
union before the single pure-pipeline pass. Folding web sources into the same
union means dedupe/filter/tag/cap and longevity classification are **shared,
unchanged** code paths — a web item is indistinguishable from a feed item once
acquired. The summary shape is unchanged: `sources` = feed sources + web sources
attempted; `failed_sources` = total failures of either kind.
- *Alternative:* unify `Source` with a `type` discriminator and one polymorphic
  acquire fn. Rejected for now — D2 of `add-curation-job` already chose a
  sibling `web_sources` list as the forward-compatible path, and two focused
  seams are clearer than a type-tagged dispatch. A unified model can replace
  both later if a third source kind appears.

### D5. Lightpanda invocation = `std.process.Child` with args `[fetch, --dump, <format>, <url>]`, stdout captured, bounded by the existing run timeout
`acquireWeb` spawns the configured binary with exactly those argv, captures
stdout into an allocating writer, and treats a zero exit + non-empty stdout as
success. The run's existing `timeout` bounds the wait. No stdin, no env beyond
the child's inherited environment, no CDP/WebSocket. This is the laziest
faithful invocation of `lightpanda fetch --dump <markdown|html> <url>` from
FR-14/Decision #3.
`// ponytail: one subprocess spawn per URL, inherited env, no persistent
// lightpanda serve session; switch to CDP/WebSocket if URL volume makes spawn
// overhead matter (Decision #3 ceiling).`
- *Alternative:* a persistent `lightpanda serve` session reused across URLs.
  Rejected — premature; spawn-per-URL is fine at digest volume and is exactly
  the ceiling Decision #3 names for a later revisit.

### D6. `dump_format` is `markdown` by default with `html` allowed; the config is additive and defaulted
`LightpandaConfig = { path: "lightpanda", dump_format: .markdown }` and
`web_sources: []const Source = &.{}`. When `lightpanda` is absent the defaults
apply; when `web_sources` is absent it is empty. Unknown fields stay ignored
(the loader already sets `ignore_unknown_fields`), so an existing config file
loads unchanged. `dump_format` is a small enum so the argv is always well-formed
(no string interpolation into argv; the URL is a single argv element, so there
is no shell-injection surface).

## Risks / Trade-offs

- **[Lightpanda not installed]** → Mitigated (D3): a missing binary is a
  per-source error, skipped + logged + counted, never a crash or an abort. The
  rest of the run (feeds + other web sources) proceeds.
- **[A slow/hung render blocks the run]** → Mitigated (D5): the spawn is bounded
  by the run's existing `timeout`; a timeout is a per-source failure like any
  other.
- **[Web items pollute the knowledge stream]** → Accepted/low: web items are
  classified by the **same** longevity evaluator as feed items, with the same
  `unknown`→default-kind fallback. No new misfiling risk is introduced beyond
  what already exists for feeds.
- **[Spawn-per-URL overhead at volume]** → Accepted (D5/Decision #3): one spawn
  per web source per day is fine; the persistent-session ceiling is a documented
  later revisit, not this slice.
- **[Title = source name weakens the EPUB digest]** → Accepted (D2): the body is
  the content; a real title is a documented refinement ceiling, not a v1
  blocker.
- **[No shell, no injection]** → Not a risk: argv is built as discrete elements
  (`std.process.Child`), never a shell string, so the URL cannot inject flags or
  commands.

## Migration Plan

Greenfield and additive — no migration. Deploy by: nothing required at startup
beyond the existing config; an operator who wants web articles adds a
`web_sources` list and (optionally) a `lightpanda` block to config and ensures
the Lightpanda binary is on the configured path, then waits for the next 04:00
(or sends one `POST /curate`). Existing config files without `web_sources`/
`lightpanda` parse as before (empty web-source list, default Lightpanda path/
format), so a deployment without Lightpanda is unaffected. No change to
`/download`, `/curate`, `/healthz`, `/metrics`, `GET /`, the store file format,
tokens, or the EPUB kinds. Rollback is `git revert` (web sources are no longer
acquired; the run reverts to feeds-only; `failed_sources` no longer counts web
failures; `/download` behavior is unchanged).

## Open Questions

- None blocking. The exact `dump_format` enum set (`markdown`, `html`) is the v1
  starting set; if a future Lightpanda build adds another dump format, extend the
  enum (additive, non-breaking). Whether to surface a `web_sources`-vs-`sources`
  split in the run summary is an operator-ergonomics detail left to a later
  metrics slice (US-006); today both fold into `sources`/`failed_sources`.
