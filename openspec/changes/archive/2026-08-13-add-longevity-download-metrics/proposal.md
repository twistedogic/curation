## Why

`add-curation-metrics` closed the bulk of US-006 by exposing the curation-run
counters — runs, items fetched, items curated per kind, source fetch errors,
items pruned — on `GET /metrics`. It deliberately stopped short of the two
remaining operations US-006 names, and said so in its own Non-Goals, Impact, and
Risks: "per-kind **EPUB generations** and **`pi`-evaluation count/latency/
failures** … are left to a follow-up change … so US-006 is not silently
considered closed," and "the follow-up change is the obvious next slice."
Today an operator scraping `/metrics` sees curation health but is blind to the
two most failure-prone, cost-bearing operations: whether downloads are actually
producing EPUBs (and which kind), and whether the `pi` longevity classifier is
being called, how long each call takes, and how often it fails. A silent `pi`
outage (every survivor falling back to `news`) or a broken EPUB path is
invisible to the only dashboard the server exposes.

This change is that named follow-up — the smallest slice that closes US-006.
The registry already exists and already renders Prometheus text; the
`longevity` evaluator and the `download` resolver already run on every
classification and every download. The lazy path is the same one
`add-curation-metrics` took for the curation run: hand each seam a nullable
handle to the existing registry and let it record its own operation at the one
chokepoint both callers funnel through. No new capability, no new thread, no new
route, no new clock source. `zig build test` stays green.

## What Changes

- Extend the **`server` metrics registry** (`src/metrics.zig`) with the two
  deferred families and their recording methods: a per-kind EPUB-generations
  counter `curation_epub_generations_total{kind="news"|"knowledge"}`; and the
  `pi`-evaluation trio — `curation_pi_evaluations_total` (counter),
  `curation_pi_evaluations_failed_total` (counter), and
  `curation_pi_evaluation_duration_seconds` (histogram, reusing the registry's
  existing fixed-bucket machinery). `render` emits the new families alongside
  the existing request/histogram/uptime/curation-run output, at zero before any
  activity. The `GET /metrics` route, content type, and open (unauthenticated)
  access are unchanged.
- Modify the **`longevity` capability** so `classify` accepts an optional
  metrics recorder (a nullable handle, mirroring the log writer it already
  takes) and, for each classification that reaches an actual `pi` invocation (a
  cache miss — a cache hit is not an evaluation), records one evaluation, the
  invocation's latency, and — when the invocation errors or its result is
  unparseable (`unknown`) — one failure. Recording is non-fatal and never
  changes the returned `Kind`.
- Modify the **`download` capability** so `resolve` accepts an optional metrics
  recorder and records one EPUB generation labeled by the resolved `kind` each
  time it builds an EPUB (a non-empty range); a nothing-new (empty-range)
  resolution records nothing.
- Thread the registry through the two existing call sites that already hold the
  `*Metrics` — the `server` capability's download resolver
  (`resolveAndRespond` → `download.resolve`) and the `curation-job`
  capability's `longevity.classify` call. No HTTP route, status code,
  request/response contract, auth ordering, token, EPUB structure, store,
  config, or record-format change.
- Standard library only; `zig build test` stays green. No new dependency, no
  provider credentials, no new EPUB kind, and no change to any stored item.

## Capabilities

### New Capabilities
<!-- none — both concerns extend existing capabilities -->

### Modified Capabilities
- `server`: the "Prometheus metrics endpoint" requirement's required metric set
  grows beyond the request-plane trio (HTTP request counter, latency histogram,
  uptime gauge) and the curation-run counters to also include a per-kind
  EPUB-generations counter and the `pi`-evaluation count, failure, and
  latency-histogram families. The prior "out of scope" carve-out for these two
  operations is removed. The `GET /metrics` route, its
  `text/plain; version=0.0.4` content type, and its open (no-auth) access are
  unchanged.
- `longevity`: a new "Evaluation observability" requirement — `classify`
  records per actual `pi` invocation (count, latency, failure) into an
  injected, nullable registry; a cache hit records nothing; recording is
  non-fatal. The label-to-kind mapping, strict parsing, failure tolerance,
  evaluation cache, and evaluation-configuration requirements are unchanged.
- `download`: a new "EPUB generation observability" requirement — `resolve`
  records one per-kind EPUB generation into an injected, nullable registry on a
  non-empty resolve; a nothing-new resolve records nothing; recording is
  non-fatal. The token codec, EPUB builder, structural validity, incremental
  resolver semantics, and capability boundary are unchanged.

## Impact

- **Code:** `src/metrics.zig` gains the EPUB-generation counter pair, the
  `pi`-evaluation counter pair, the `pi`-evaluation latency-histogram store and
  its aggregation in `render`, two recording methods (`recordEpubGeneration`,
  `recordPiEval`), and self-checks; `src/longevity.zig` widens `classify` by a
  trailing optional `metrics: ?*metrics_mod.Metrics` and records on the
  cache-miss invoke path; `src/download.zig` widens `resolve` by the same
  optional param and records on a non-empty resolve; `src/server.zig` passes
  `deps.metrics` into `resolveAndRespond` and through to `download.resolve`;
  `src/curation_job.zig` passes its `metrics` handle into `longevity.classify`.
  `fetch.zig`, `feed.zig`, `curation.zig`, `store.zig`, `render.zig`,
  `config.zig`, `ui.zig`, `auth.zig`, `log.zig`, `opml.zig`, and `item.zig` are
  consumed unchanged.
- **APIs:** no HTTP route or status change. `GET /metrics` returns the same
  `200 text/plain; version=0.0.4` body, now also containing the EPUB-generation
  and `pi`-evaluation families. No other endpoint's contract changes. The
  `classify` and `resolve` signatures widen by one optional trailing param;
  they are internal library seams, not HTTP contracts.
- **Dependencies:** none added — Zig 0.16 standard library only. Stays a single
  binary; no external runtime dependency.
- **Data:** no store, config, eval-cache, or record-format change. Metrics are
  in-memory process state reset on restart (consistent with the existing
  counters and uptime gauge). The longevity eval cache and the JSONL store are
  untouched.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the new
  registry self-checks (the new families render at zero; counters and the
  histogram increment and render in Prometheus text) and the two seams record
  correctly (a cache-miss evaluation bumps the count and a latency sample and,
  on error/unparseable, the failure counter; a cache hit bumps nothing; a
  non-empty resolve bumps the kind's generation counter; a nothing-new resolve
  bumps nothing; a `null` recorder is a no-op).
- **Scope note:** this closes US-006 — every operation the story names
  (curation runs, items fetched / items curated per kind, source fetch errors,
  EPUB generations per kind, `pi` evaluations count/latency/failures, request
  counts/latency) is now exposed on `/metrics`.
