## Why

After seven archived changes `curation` has every server-side ingredient for
delivery: the HTTP surface and config (`add-server`), the pure
normalize/dedupe/filter/tag/cap pipeline (`add-curation-pipeline`), feed
fetching + parsing (`add-feed-fetching`), the `pi` longevity evaluator
(`add-longevity-evaluator`), the append-only JSONL store with global monotonic
ids and a per-kind range query (`add-storage`), the kind-scoped token codec +
stdlib EPUB builder + resolver and the bearer-gated `GET /download`
(`add-epub-download`), and the embedded download page + first-download
bootstrap (`add-download-ui`). But the store is never populated: nothing wires
fetch → curate → longevity → store together, so `/download` returns `204`
forever and the page always shows "nothing new." The pure `curation.curate`
stops at the cap; `fetch.acquireFeed`, `longevity.classify`, and `store.append`
exist but have no caller.

Intent US-002 / FR-7 / Decision #8 require exactly this glue: a curation run
that fetches/renders all configured sources, dedupes, filters, tags, caps,
evaluates each survivor's longevity via `pi`, and stores the survivors split
into the `news` and `knowledge` streams — driven two ways, both mandatory: a
built-in daily scheduler (default 04:00 local) and a synchronous
`POST /curate` (the canonical job entry point for external cron and manual
runs). One misbehaving source must never abort the run. This change is that
orchestration. It is deliberately the slice that makes `curation` actually
produce content.

## What Changes

- Add a new **`curation-job` capability**: a single, synchronous, library-callable
  `run` that orchestrates one curation pass end-to-end — for each configured
  **feed** source, acquire (fetch + parse) with per-source error isolation;
  gather all items; run the pure `curation` pipeline (dedupe/filter/tag/cap) over
  them; for each surviving item classify its longevity via the `longevity`
  capability (`pi`, cache-backed, failure-tolerant); and append each survivor to
  the `storage` store under the `Kind` the classifier returned (`news` or
  `knowledge`). It returns a small summary (sources seen, items fetched, items
  curated, items stored per kind, sources that failed). It owns **no** HTTP
  serving, scheduling, fetching internals, evaluation internals, or storage
  internals — it composes the existing capabilities.
- Serialize runs **one at a time** in the `curation-job` capability via an
  internal mutex exposed as a non-blocking `tryRun`: a caller that finds a run in
  progress observes `busy` instead of starting a second concurrent run. This
  prevents two overlapping runs from appending the same items twice (the pipeline
  dedupes *within* a run, never *across* runs).
- Add **`sources` and `schedule` to the config schema** (server-owned config): a
  list of feed sources (`{ name, url }`) and a daily local time string
  (`"HH:MM"`, default `"04:00"`). Unknown fields stay ignored, so this is
  additive and non-breaking.
- Modify the **`server` capability** to (a) add a **`POST /curate`** route —
  bearer-gated (same gate as `/download`), runs the job via `tryRun` and returns
  `200` with a small JSON summary, or `409 Conflict` when a run is already in
  progress, or `401` on a missing/wrong bearer; and (b) start a **daily
  scheduler** thread in `serveCommand` that sleeps until the next configured
  local time, calls `tryRun` (skipping + logging on `busy`), and cooperates with
  the existing SIGINT graceful-shutdown path.
- Modify the **`storage` capability** to make `append` and `range` thread-safe
  via an internal mutex, so the scheduler/`POST /curate` job (which writes) and
  the serving thread (which reads `/download` ranges) never race. This is the
  mutex the store explicitly deferred to "the orchestration change."
- Standard library only; `zig build test` stays green. No Lightpanda web
  rendering, no extended Prometheus metrics, and no age-based retention in this
  change — those remain later slices (US-008, US-006, FR-16).

## Capabilities

### New Capabilities
- `curation-job`: The end-to-end daily curation run — composes `sources`
  (acquire each feed), `curation` (the pure pipeline), `longevity` (classify each
  survivor via `pi`), and `storage` (append each survivor under its `Kind`), with
  per-source error isolation and one-run-at-a-time serialization. Returns a run
  summary. Owns no HTTP serving, scheduling, fetching/evaluating/storage
  internals, token codec, or EPUB generation.

### Modified Capabilities
- `server`: gains `sources` (feed sources) and `schedule` (daily local time,
  default `04:00`) fields in the JSON config schema it owns; gains a bearer-gated
  `POST /curate` route that runs the `curation-job` synchronously (`200` +
  summary, or `409` if a run is in progress, or `401`); and starts a daily
  scheduler thread that runs the same job at the configured local time and stops
  with the server. Holds the store as a mutable handle so the storage mutex can
  be taken. The `/download`, `/healthz`, `/metrics`, and `GET /` contracts are
  unchanged.
- `storage`: gains an internal mutex serializing `append` and `range` (and the
  in-memory index they touch), making the store safe for one writer (the job)
  concurrent with reader threads (the `/download` serving path). No change to the
  file format, id semantics, range half-open semantics, or capability boundary.

## Impact

- **Code:** new `src/curation_job.zig` (the `run`/`tryRun` orchestration + run
  summary + one-at-a-time mutex, with a stubbed-source self-check); `src/config.zig`
  gains `Source`, `sources`, and `schedule` fields with deep-copy/free in
  `load`/`deinit`; `src/store.zig` gains a `std.Thread.Mutex` locked in `append`
  and `range`; `src/server.zig` adds the `POST /curate` branch in `handleRequest`
  (auth-first, like `/download`), a `handleCurate` that calls `curation-job.tryRun`
  and shapes the `200`/`409`/`401` response, a scheduler thread spawned (and
  joined on shutdown) in `serveCommand`, and constructs the shared `std.http.Client`
  and `longevity.EvalCache` passed to the job; `src/main.zig` registers
  `curation_job.zig` in its comptime test import block. `curation.curate`,
  `fetch.acquireFeed`, `longevity.classify`, and `download` are consumed
  unchanged.
- **APIs:** new `POST /curate` (bearer-gated) returning a small JSON summary on
  `200`, `409` when a run is in progress, `401` on auth failure; the route is
  protected, so it is added to the bearer gate. No change to `GET /`,
  `/healthz`, `/metrics`, or `GET /download`. The store gains no public API
  change beyond internal locking.
- **Dependencies:** none added — Zig 0.16 standard library only
  (`std.Thread`, `std.http.Client`, `std.json`). Stays a single binary.
- **Data:** no new persistent server-side files beyond those the job's
  dependencies already own (the JSONL store under `$XDG_DATA_HOME/curation/` and
  the longevity cache under `$XDG_CACHE_HOME/curation/`). Once the job runs, the
  store is populated and `/download` returns real EPUBs; before the first run the
  store may be empty and `/download` correctly returns `204` (unchanged behavior).
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the job
  self-check (per-source isolation, split into kinds, cap respected, one-at-a-time
  serialization), the `POST /curate` route (200/409/401), the config
  `sources`/`schedule` parsing, and the store's concurrent append/range.
