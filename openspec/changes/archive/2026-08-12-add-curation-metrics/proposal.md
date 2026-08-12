## Why

After eleven archived changes, `curation` has the full acquire → curate →
classify → store → serve pipeline, run daily by a scheduler and on demand by
`POST /curate` (`add-server`, `add-curation-job`, and the rest). It even has a
metrics module and a `GET /metrics` scrape endpoint. But look at what
`src/metrics.zig` actually records: an HTTP request counter, an HTTP request
latency histogram, and a process uptime gauge — nothing else. None of the
curation domain the operator cares about is observable.

That is exactly the gap the intent's observability story names. `.see/intent.md`
**US-006** requires Prometheus metrics covering "curation runs, items
fetched/items curated per kind, source fetch errors, EPUB generations per kind,
`pi` evaluations (count/latency/failures), request counts/latency," and **FR-11**
requires metrics counters/gauges/histograms "on the operations above." The
`server` capability's "Prometheus metrics endpoint" requirement was deliberately
scoped to "The **initial** metric set SHALL include an HTTP request counter and
… latency histogram … plus a process uptime gauge" — i.e. it shipped the
request-plane metrics and left the curation-plane metrics for a later slice.
Today an operator scraping `/metrics` can see that *the server answered
requests*, but cannot see *whether curation ran, how many items it fetched or
curated, or how many sources failed*. A silent feed outage (every source 404ing)
is invisible to the only dashboard the server exposes.

This change is that later slice — the smallest one that closes the bulk of
US-006. The curation job already computes every number US-006 asks for and
returns it in its run `Summary` (`sources`, `fetched`, `curated`, `news`,
`knowledge`, `failed`, `pruned`). So the lazy path is: extend the existing
metrics registry with the curation counters, hand the job a handle to that
registry (the same way it already receives a log writer), and have the run
record its own summary at the end of a run. No new capability, no new thread,
no new clock — the run is already the single chokepoint both `POST /curate` and
the daily scheduler funnel through (`tryRun`). `zig build test` stays green.

## What Changes

- Extend the **`server` metrics registry** (`src/metrics.zig`) with typed
  curation counters and their Prometheus exposition families:
  `curation_runs_total` (counter), `curation_items_fetched_total` (counter),
  `curation_items_curated_total{kind="news"|"knowledge"}` (counter),
  `curation_source_fetch_errors_total` (counter), and
  `curation_items_pruned_total` (counter). The registry gains recording methods
  for each; `render` emits the new families alongside the existing request
  counter, latency histogram, and uptime gauge. The `GET /metrics` route,
  content type, and open (unauthenticated) access are unchanged.
- Modify the **`curation-job` capability** so a run accepts an optional metrics
  recorder (a nullable handle to the registry, mirroring the log writer it
  already takes) and, at the end of a run that actually executed (not a `.busy`
  probe), records its run summary into it: one run, the items fetched, the items
  stored per `Kind` (`news`, `knowledge`), the failed-source count, and the
  pruned count. A recording failure is logged and never aborts the run.
- Thread the registry through the two existing `tryRun` call sites in the
  `server` capability — the `POST /curate` handler and the daily scheduler —
  which already hold the `*Metrics`. No HTTP route, status code, request/response
  contract, auth ordering, scheduler timing, or one-run-at-a-time serialization
  changes.
- Standard library only; `zig build test` stays green. No new EPUB kind, no
  provider credentials, and no change to any stored item.

## Capabilities

### Modified Capabilities
- `server`: the "Prometheus metrics endpoint" requirement's required metric set
  grows beyond the initial request-plane trio (HTTP request counter, latency
  histogram, uptime gauge) to also include the curation-run counters (runs,
  items fetched, items curated per kind `news`/`knowledge`, source fetch errors,
  items pruned). The registry gains the recording methods and `render` emits the
  new families. The `GET /metrics` route, its `text/plain; version=0.0.4`
  content type, and its open (no-auth) access are unchanged.
- `curation-job`: a run now accepts an optional metrics recorder and records its
  run summary (run, items fetched, items stored per `Kind`, failed sources,
  pruned) at the end of a run that executed; a `.busy` probe records nothing.
  The one-at-a-time serialization, the per-source error isolation, the
  acquire/pipeline/classify/append/prune order, the capability boundary, and the
  summary's existing fields are unchanged.

## Impact

- **Code:** `src/metrics.zig` gains the five curation counters, their recording
  methods, and their exposition lines in `render`, plus self-checks;
  `src/curation_job.zig` adds a trailing optional `metrics: ?*metrics_mod.Metrics`
  parameter to `run`/`tryRun` and one record call at the end of `run` fed by the
  summary it already builds, plus a self-check; `src/server.zig` passes
  `&metrics` at the two `tryRun` call sites. `fetch.zig`, `feed.zig`,
  `curation.zig`, `longevity.zig`, `download.zig`, `store.zig`, `render.zig`,
  `config.zig`, and `ui.zig` are consumed unchanged.
- **APIs:** no HTTP route or status change. `GET /metrics` returns the same
  `200 text/plain; version=0.0.4` body, now also containing the curation counter
  families. `POST /curate` and the scheduler response contracts (bearer gate,
  `200` + summary / `409` / `401`; scheduler skip-on-busy) are unchanged. The
  `curation-job` `run`/`tryRun` signatures widen by one optional trailing param;
  they are internal library seams, not an HTTP contract.
- **Dependencies:** none added — Zig 0.16 standard library only. Stays a single
  binary; no external runtime dependency.
- **Data:** no store, config, or record-format change. Metrics are in-memory
  process state reset on restart (consistent with the existing request counter
  and uptime gauge). Nothing is persisted.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the new
  registry self-checks (counters increment and render in Prometheus text) and
  the job records-its-summary self-check (a run with a registry handle bumps the
  run/items/source counters; a `.busy` probe bumps nothing).
- **Scope note (deferred):** this slice records the metrics the run `Summary`
  already holds. US-006 also names per-kind **EPUB generations** and **`pi`
  evaluation count/latency/failures**; those require threading the recorder (and
  a timer) into the `download` and `longevity` seams and are left to a follow-up
  change. Called out explicitly so US-006 is not silently considered closed.
