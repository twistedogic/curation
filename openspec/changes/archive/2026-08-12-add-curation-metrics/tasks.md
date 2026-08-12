## 1. Curation counters in the registry (server capability)

- [ ] 1.1 In `src/metrics.zig`, add monotonic counter fields to `Metrics`:
  `runs_total: u64`, `items_fetched_total: u64`, `items_curated_news: u64`,
  `items_curated_knowledge: u64`, `source_fetch_errors_total: u64`,
  `items_pruned_total: u64` — all initialized to `0` in `init`. No allocation;
  plain `u64` value fields (design D4, D5; spec: Prometheus metrics endpoint).
- [ ] 1.2 Add a single recording method
  `pub fn recordCurationRun(self: *Metrics, fetched: u64, news: u64, knowledge: u64, source_errors: u64, pruned: u64) void`
  that bumps the six counters (`runs_total += 1`, plus the five passed counts).
  One method, called once per executed run (design D3, D6; spec: Prometheus
  metrics endpoint).
- [ ] 1.3 In `render`, emit the five counter families in Prometheus text format
  after the existing request/histogram/uptime output:
  `curation_runs_total` (counter, no labels), `curation_items_fetched_total`
  (counter), `curation_items_curated_total{kind="news"}` and
  `curation_items_curated_total{kind="knowledge"}` (counter, `kind` label),
  `curation_source_fetch_errors_total` (counter), and
  `curation_items_pruned_total` (counter) — each with `# HELP`/`# TYPE` lines.
  Zero-valued counters are still emitted (a scraper must see the family exists)
  (design D5; spec: Prometheus metrics endpoint).
- [ ] 1.4 Self-check (registry): a fresh `Metrics` renders all five families
  with value `0`; after `recordCurationRun(3, 2, 1, 1, 0)` then
  `recordCurationRun(5, 0, 4, 0, 7)`, `render` shows `curation_runs_total 2`,
  `curation_items_fetched_total 8`, `curation_items_curated_total{kind="news"} 2`,
  `curation_items_curated_total{kind="knowledge"} 5`,
  `curation_source_fetch_errors_total 1`, `curation_items_pruned_total 7`, and
  the existing `curation_http_requests_total`/uptime lines are still present
  (design D4, D5; spec: Prometheus metrics endpoint).
- [ ] 1.5 Self-check (registry): HTTP request observations still render exactly
  as before (no regression to the existing counter/histogram/uptime output);
  `curation_items_curated_total` carries only the `kind` label, no `method`/`path`
  labels (design D5; spec: Prometheus metrics endpoint).

## 2. Record after a run (curation-job capability)

- [ ] 2.1 In `src/curation_job.zig`, import `metrics_mod` (`@import("metrics.zig")`)
  and add a trailing optional parameter
  `metrics: ?*metrics_mod.Metrics` to `run` and to `tryRun` (after
  `retention_days`). Both internal call sites of `run` (the one inside `tryRun`)
  forward the same handle (design D2, D3; spec: One curation run).
- [ ] 2.2 At the end of `run`, after the append loop and the optional prune,
  with the final `summary` already built, if `metrics` is non-null call
  `metrics.?.recordCurationRun(summary.fetched, summary.news, summary.knowledge,
  summary.failed, summary.pruned)`. Wrap the call site so an error is impossible
  (`recordCurationRun` is infallible); a null handle records nothing. Do not
  record in `tryRun`'s `.busy` branch (design D3, D6; spec: One curation run).
- [ ] 2.3 Map summary fields to counters exactly: `fetched → items_fetched`,
  `news → items_curated{kind=news}`, `knowledge → items_curated{kind=knowledge}`,
  `failed → source_fetch_errors`, `pruned → items_pruned`, and one
  `runs_total += 1` per call (design D5; spec: One curation run).
- [ ] 2.4 Self-check (job): with stubbed acquire + pi and a real `Metrics`,
  run once producing `news=2, knowledge=1, fetched=3, failed=0, pruned=0`; assert
  `metrics` afterwards renders `curation_runs_total 1`,
  `curation_items_curated_total{kind="news"} 2`,
  `curation_items_curated_total{kind="knowledge"} 1`,
  `curation_items_fetched_total 3` (design D2, D3; spec: One curation run).
- [ ] 2.5 Self-check (job): a second run that fails one source and prunes two
  records bumps `curation_runs_total` to `2`, `curation_source_fetch_errors_total`
  to `1`, and `curation_items_pruned_total` to `2` (design D4; spec: One curation
  run).
- [ ] 2.6 Self-check (job): a `tryRun` that returns `.busy` records nothing —
  the counters are unchanged by the busy probe (design D3; spec: One run at a
  time).
- [ ] 2.7 Self-check (job): a run with `metrics = null` still completes and
  returns its summary unchanged — the job stays usable with no registry
  (design D2; spec: One curation run).

## 3. Wiring (server capability)

- [ ] 3.1 In `src/server.zig`, pass `&metrics` as the new trailing argument to
  `tryRun` at both call sites — the `POST /curate` handler (`handleCurate`) and
  the daily scheduler loop. No change to the route contract, status codes, auth
  ordering, scheduler timing, or the `.busy`/`.ran` handling (design D1, D3;
  spec: Prometheus metrics endpoint, Curate endpoint, Daily scheduler).
- [ ] 3.2 Self-check (route handler): a `POST /curate` with a valid bearer and
  stubbed acquisition returns `200 application/json` as before, and a subsequent
  `GET /metrics` reflects the run's counters (run + items per kind) (spec:
  Prometheus metrics endpoint, Curate endpoint).
- [ ] 3.3 Self-check (route handler): `GET /metrics` stays open (200 with no
  credentials) and its body still contains the existing request counter,
  histogram, and uptime gauge in addition to the new curation families (spec:
  Prometheus metrics endpoint).

## 4. Integration

- [ ] 4.1 No new module to register (`metrics.zig` is already imported by
  `server.zig` and registered in `main.zig`'s comptime test block; `curation_job.zig`
  already registered).
- [ ] 4.2 `zig build test` green; `openspec validate add-curation-metrics` passes.
