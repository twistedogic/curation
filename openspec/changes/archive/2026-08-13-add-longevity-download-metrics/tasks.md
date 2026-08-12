## 1. Registry families (server capability)

- [ ] 1.1 In `src/metrics.zig`, add monotonic counter fields to `Metrics`:
  `epub_generations_news: u64 = 0`, `epub_generations_knowledge: u64 = 0`,
  `pi_evaluations_total: u64 = 0`, `pi_evaluations_failed_total: u64 = 0`, and a
  latency sample list `pi_eval_latencies: std.ArrayList(u64)` (nanoseconds per
  actual `pi` invocation), initialized to `.empty` in `init` and freed in
  `deinit` like `observations`. No allocation per evaluation beyond the appended
  sample (design D4, D7; spec: Prometheus metrics endpoint).
- [ ] 1.2 Add `pub fn recordEpubGeneration(self: *Metrics, kind: enum { news, knowledge }) void`
  that increments `epub_generations_news` or `epub_generations_knowledge`. Called
  once per EPUB actually built by `download.resolve` (design D6, D8; spec:
  Prometheus metrics endpoint).
- [ ] 1.3 Add `pub fn recordPiEval(self: *Metrics, gpa: std.mem.Allocator, elapsed_ns: u64, failed: bool) std.mem.Allocator.Error!void`
  that does `pi_evaluations_total += 1`, appends `elapsed_ns` to
  `pi_eval_latencies` (the same append-or-error shape as `observe`), and, when
  `failed`, does `pi_evaluations_failed_total += 1`. Called once per actual
  `pi` invocation on the cache-miss path of `classify` (design D2, D3; spec:
  Prometheus metrics endpoint).
- [ ] 1.4 In `render`, emit the new families after the existing curation-run
  counters: `curation_epub_generations_total{kind="news"}` and
  `curation_epub_generations_total{kind="knowledge"}` (counter, `kind` label);
  `curation_pi_evaluations_total` (counter, no label);
  `curation_pi_evaluations_failed_total` (counter, no label); and
  `curation_pi_evaluation_duration_seconds` (histogram, no label) — aggregated
  from `pi_eval_latencies` with `findBucket` and the same bucket/_sum/_count
  shape as the HTTP request histogram, with `# HELP`/`# TYPE` lines. Zero-valued
  families are still emitted (a scraper must see the family exists)
  (design D4, D7, D8; spec: Prometheus metrics endpoint).
- [ ] 1.5 Self-check (registry): a fresh `Metrics` renders every new family at
  zero — `curation_epub_generations_total{kind="news"} 0`,
  `...{kind="knowledge"} 0`, `# TYPE curation_pi_evaluations_total counter` with
  `curation_pi_evaluations_total 0`, `curation_pi_evaluations_failed_total 0`,
  and the `curation_pi_evaluation_duration_seconds` histogram with a `+Inf`
  bucket and `_count 0` (design D4, D7; spec: Prometheus metrics endpoint).
- [ ] 1.6 Self-check (registry): after `recordEpubGeneration(.news)` twice and
  `recordEpubGeneration(.knowledge)` once, `render` shows
  `curation_epub_generations_total{kind="news"} 2` and `...{kind="knowledge"} 1`;
  after `recordPiEval(gpa, 250_000_000, false)` then
  `recordPiEval(gpa, 5_000_000, true)`, `render` shows
  `curation_pi_evaluations_total 2`, `curation_pi_evaluations_failed_total 1`,
  and a histogram `_count 2` with the two samples placed in the correct buckets
  (design D3, D4, D7; spec: Prometheus metrics endpoint).
- [ ] 1.7 Self-check (registry): the existing request counter, request-latency
  histogram, uptime gauge, and curation-run counter families still render exactly
  as before (no regression); the `pi`-evaluation histogram carries no
  `method`/`path`/`kind` label, and the EPUB-generation counter carries only the
  `kind` label (design D8; spec: Prometheus metrics endpoint).

## 2. Longevity evaluator records (longevity capability)

- [ ] 2.1 In `src/longevity.zig`, import `metrics_mod` (`@import("metrics.zig")`)
  and add a trailing optional parameter `metrics: ?*metrics_mod.Metrics` to
  `classify` (after `log_writer`). `classify`'s signature otherwise unchanged
  (design D5, D6; spec: Evaluation observability).
- [ ] 2.2 On the cache-miss invoke path — after `cache.lookup` misses, around
  `invoker.call` — read a monotonic clock before and after the call (the same
  time source the server uses for uptime/latency), compute `elapsed_ns`, and on
  return call `metrics.?.recordPiEval(gpa, elapsed_ns, failed)` when `metrics`
  is non-null, where `failed` is true iff the invocation returned an error OR
  the parsed `label == .unknown` (design D2, D3; spec: Evaluation observability).
  Record exactly once per actual invocation; the cache-hit early-return path
  records nothing.
- [ ] 2.3 A `null` `metrics` records nothing and `classify` is otherwise
  unchanged — same `Kind` returned, same cache writes, same fallback
  (design D5; spec: Evaluation observability).
- [ ] 2.4 Self-check (evaluator): with a stubbed invoker returning `long_term`
  on a cache miss and a real `Metrics`, `classify` returns `knowledge` and the
  registry afterward renders `curation_pi_evaluations_total 1`,
  `curation_pi_evaluations_failed_total 0`, and a histogram `_count 1`
  (design D2; spec: Evaluation observability).
- [ ] 2.5 Self-check (evaluator): with a stubbed invoker that errors
  (`error.PiNonZeroExit`), `classify` returns the default kind, the registry
  renders `curation_pi_evaluations_total 1` and
  `curation_pi_evaluations_failed_total 1`, and the run is not aborted; the same
  holds for a stub returning unparseable prose (`label == .unknown` → one
  failure) (design D3; spec: Evaluation observability).
- [ ] 2.6 Self-check (evaluator): a cache hit (item previously classified) does
  not invoke and records nothing — `pi_evaluations_total` is unchanged across
  the hit (design D2; spec: Evaluation observability).
- [ ] 2.7 Self-check (evaluator): `classify` with `metrics = null` still returns
  the same `Kind` and writes the cache exactly as today; update the existing
  `classify` tests to pass `null` for the new trailing param (design D5; spec:
  Evaluation observability).

## 3. Download resolver records (download capability)

- [ ] 3.1 In `src/download.zig`, import `metrics_mod` and add a trailing
  optional parameter `metrics: ?*metrics_mod.Metrics` to `resolve` (after
  `token`). `resolve`'s signature otherwise unchanged (design D5, D6; spec: EPUB
  generation observability).
- [ ] 3.2 On a non-empty resolve — after `build` succeeds and a `ResolveResult`
  is being returned — call `metrics.?.recordEpubGeneration(token.kind)` when
  `metrics` is non-null. The empty-range (`records.len == 0`) early-return
  (nothing-new) records nothing (design D6, D8; spec: EPUB generation
  observability).
- [ ] 3.3 A `null` `metrics` records nothing and `resolve` is otherwise
  unchanged — same EPUB bytes, same next token, same half-open range semantics
  (design D5; spec: EPUB generation observability).
- [ ] 3.4 Self-check (resolver): with a store whose `news` ids are `[1,3,5]` and
  a real `Metrics`, `resolve(.news, 1)` returns an EPUB and the registry renders
  `curation_epub_generations_total{kind="news"} 1`; a subsequent
  `resolve(.knowledge, 0)` over a knowledge record bumps
  `...{kind="knowledge"} 1` and leaves `news` at `1` (design D8; spec: EPUB
  generation observability).
- [ ] 3.5 Self-check (resolver): a nothing-new resolve (`records.len == 0`)
  records nothing — the EPUB-generation counters are unchanged (design D6; spec:
  EPUB generation observability).
- [ ] 3.6 Self-check (resolver): `resolve` with `metrics = null` still returns
  the same result; update the existing `resolve` tests to pass `null` for the new
  trailing param (design D5; spec: EPUB generation observability).

## 4. Wiring (server + curation-job)

- [ ] 4.1 In `src/server.zig`, pass `deps.metrics` into `resolveAndRespond` and
  through to `download_mod.resolve` at the `GET /download` call site. No change
  to the route contract, status codes (`200`/`204`/`400`/`401`), auth ordering,
  `X-Next-Token` handling, or content type (design D6; spec: Prometheus metrics
  endpoint, Download endpoint).
- [ ] 4.2 In `src/curation_job.zig`, pass the run's `metrics` handle (the same
  nullable handle `add-curation-metrics` threaded into `run`/`tryRun`) into
  `longevity_mod.classify` at the classify call site. No change to the pipeline
  order, per-source error isolation, one-at-a-time serialization, or the run
  summary (design D6; spec: Evaluation observability).
- [ ] 4.3 Self-check (server route): a `GET /download` that yields an EPUB,
  followed by `GET /metrics`, shows `curation_epub_generations_total{kind=…}`
  incremented for the resolved kind; a `GET /download` that returns `204`
  (nothing new) does not increment it (spec: Prometheus metrics endpoint,
  Download endpoint).
- [ ] 4.4 Self-check (curation-job): a run with a stubbed `pi` that invokes on a
  cache miss bumps `curation_pi_evaluations_total`; a run whose `pi` errors or
  returns unparseable output also bumps `curation_pi_evaluations_failed_total`;
  the existing run-summary counters (`runs_total`, items per kind, source errors,
  pruned) are still recorded (design D2, D3; spec: Evaluation observability, One
  curation run).

## 5. Integration

- [ ] 5.1 No new module to register (`metrics.zig`, `longevity.zig`, and
  `download.zig` are already imported by `server.zig`/`curation_job.zig` and
  registered in `main.zig`'s comptime test block).
- [ ] 5.2 `zig build test` green; `openspec validate add-longevity-download-metrics`
  passes.
