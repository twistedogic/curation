## Why

`curation` fetches RSS/Atom feeds, but the intent's data flow is explicit that
sources are **two kinds**: feeds fetched directly over HTTP, and **web-content
sources rendered via the Lightpanda headless browser** (`.see/intent.md` §1,
US-008, FR-14). Every archived change so far has deferred the second kind. The
`sources` spec says it plainly — "Web-content sources (rendered out-of-process
via Lightpanda) are added in a later change" — and `add-curation-job`'s design
D2 paved the way: "US-008 can extend the source model later (… a sibling
`web_sources` list)". So today a configured web page is simply never acquired:
`curation-job.run` takes only feed sources and one feed-shaped `AcquireFn`, and
`fetch.zig` only knows `std.http.Client`. JS-heavy pages — the whole reason
Lightpanda is in the design — never reach the digest.

Intent US-008 / FR-14 / Decision #3 fix the contract: web-content URLs are
rendered out-of-process by `lightpanda fetch --dump <markdown|html> <url>` (path
and dump format configurable); the rendered output **is** the item body (no
separate readability step — Lightpanda's `--dump` is the extraction layer); if
Lightpanda is missing or a render fails, that source is skipped and logged and
the run continues. curation stays a single binary: Lightpanda is a configured
sidecar tool, never vendored. This change is that acquisition path and its
wiring into the daily run. It is the slice that lets the digest contain full
web articles, not just feed entries.

## What Changes

- Add a new **web-content acquisition path in the `sources` capability**
  (`src/render.zig`): `acquireWeb` renders one web-content URL out-of-process by
  spawning `<lightpanda.path> fetch --dump <lightpanda.dump_format> <url>` as a
  child process, capturing its standard output, and returning **exactly one**
  `Item` whose `body` is the captured output verbatim, `url` is the source URL,
  and `title`/`source` are the source name (web pages carry no structured title
  field; the body is the content). It performs no HTTP of its own (Lightpanda
  fetches) and no feed parsing. A missing binary, a non-zero exit, a timeout, or
  empty stdout is reported as an error — it never crashes.
- Modify the **`curation-job` capability** so a run acquires **web sources in
  addition to feed sources**: `run`/`tryRun` gain a `web_sources` list, a
  Lightpanda configuration, and a `WebAcquireFn` seam. The run acquires feeds
  first, then web sources, gathering all items into the same union before the
  existing pure pipeline, longevity classification, and storage. Web render
  failures are per-source failures (logged + counted in `failed_sources`, never
  abort), identical in spirit to a feed fetch/parse failure. The summary shape
  is unchanged — `sources` counts feeds + web sources attempted.
- Modify the **`server` capability's** JSON config schema to add a `web_sources`
  list (`{ name, url }`, defaulting to empty) and a `lightpanda` object
  (`{ path: "lightpanda", dump_format: "markdown" }`, both defaulted when the
  block is absent). The two `tryRun` call sites (the `POST /curate` handler and
  the daily scheduler) pass the new `web_sources`, the Lightpanda config, and
  `render.acquireWeb`. Unknown fields stay ignored, so this is additive and
  non-breaking.
- Standard library only; `zig build test` stays green. No new EPUB kind (items
  still split into exactly `news`/`knowledge` by the existing longevity
  evaluator), no provider credentials (Lightpanda is local; `pi` still owns the
  model), and no age-based retention (FR-16 stays a later slice).

## Capabilities

### Modified Capabilities
- `sources`: gains a web-content acquisition path that renders a URL via the
  Lightpanda headless browser out-of-process and returns one item per web
  source, sibling to the existing feed fetch+parse path. It performs no HTTP of
  its own and no feed parsing; a render failure is an error, not a crash. The
  feed path, the parser, and the per-source error isolation contract are
  unchanged.
- `curation-job`: a run now acquires configured web sources in addition to feed
  sources (new `web_sources` input + a Lightpanda config + a `WebAcquireFn`
  seam), feeding the same union of items into the unchanged pure pipeline,
  longevity classification, and storage. Web render failures count as
  per-source failures exactly like feed fetch/parse failures. The summary
  struct, the one-run-at-a-time serialization, and the capability boundary are
  unchanged.
- `server`: the JSON config schema it owns gains a `web_sources` list and a
  `lightpanda` object (both defaulted when absent); the two `tryRun` call sites
  (the `POST /curate` route and the daily scheduler) pass the new inputs and
  `render.acquireWeb`. The `/download`, `/curate`, `/healthz`, `/metrics`, and
  `GET /` contracts, the bearer gate, and the scheduler timing are unchanged.

## Impact

- **Code:** new `src/render.zig` (`acquireWeb` + the Lightpanda subprocess
  invocation + a self-check with a stubbed child path); `src/config.zig` gains a
  `LightpandaConfig` struct (`path`, `dump_format`), `Config` fields
  `web_sources: []const Source` and `lightpanda: LightpandaConfig`, with
  deep-copy/free in `load`/`deinit` mirroring the existing `copySources`
  helper; `src/curation_job.zig` adds a `WebAcquireFn` seam and `web_sources` +
  Lightpanda-config + `web_acquire` parameters to `run`/`tryRun`, and gathers
  web items into the same `flat_items` list; `src/server.zig` updates the two
  `tryRun` call sites to pass `cfg.web_sources`, `cfg.lightpanda`, and
  `render_mod.acquireWeb`; `src/main.zig` registers `render.zig` in its
  comptime test import block. `fetch.zig`, `feed.zig`, `curation.zig`,
  `longevity.zig`, `store.zig`, and `download.zig` are consumed unchanged.
- **APIs:** no HTTP route or status change. `POST /curate` and the daily
  scheduler now also acquire web sources, but their request/response contracts
  (bearer gate, `200` + summary / `409` / `401`; scheduler skip-on-busy) are
  unchanged. The `curation-job` `run`/`tryRun` signatures widen (new params);
  they are internal library seams, not an HTTP contract.
- **Dependencies:** none added — Zig 0.16 standard library only
  (`std.process.Child`, `std.json`). Stays a single binary; Lightpanda is a
  configured external tool, not a vendored library.
- **Data:** no new persistent server-side files. Once the job runs with
  `web_sources` configured, web items are appended to the same JSONL store and
  appear in the next `/download` of their kind. An operator without Lightpanda
  installed who configures `web_sources` sees those sources skipped + logged on
  each run (counted in `failed_sources`), exactly like a dead feed.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the render
  self-check (stubbed subprocess: success → one item; missing binary → error;
  non-zero exit → error; no HTTP/parse), the config `web_sources`/`lightpanda`
  parsing, and the job acquiring web sources alongside feeds (web survivors
  stored under their classified kind; a failing web source increments
  `failed_sources` without aborting).
