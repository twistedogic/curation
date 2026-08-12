## Context

`curation` runs unattended: a daily scheduler and `POST /curate` both drive one
end-to-end curation run (`add-curation-job`), which acquires feed and web
sources, runs the deterministic pipeline, classifies each survivor's longevity
via `pi` (`add-longevity-evaluator`), appends survivors to the JSONL store, and
prunes old records by age (`add-retention`). Clients pull incremental EPUBs per
kind through `GET /download`, resolved by the `download` capability's resolver
(`add-epub-download`). The `server` capability (`add-server`) owns config, the
bearer gate, the routes, and a metrics registry exposed at `GET /metrics`.

The registry grew its curation-plane counters in `add-curation-metrics`: beyond
the request counter, request-latency histogram, and uptime gauge, a run now
records runs / items fetched / items curated per kind / source fetch errors /
items pruned into the registry it is handed. That change was explicit that it
advanced but did not close US-006. Its Non-Goals, Impact, and Risks all name the
two operations it left out — per-kind **EPUB generations** and `pi`-evaluation
**count / latency / failures** — as "the obvious next slice," because they live
in different seams (the `download` resolver and the `longevity` evaluator) than
the curation run and so could not ride the run's existing `Summary`.

Those two seams are already chokepoints. `download.resolve` is the single
function that builds an EPUB — it is called from exactly one place
(`server.resolveAndRespond` at `GET /download`) and it knows the `kind` it is
building for. `longevity.classify` is the single function that invokes `pi` —
it is called from exactly one place (`curation_job.run`) and it already knows
whether the call was a cache hit (no invocation) or a real invocation, and
whether that invocation failed or produced an unparseable label. So every number
US-006 still asks for is already known at the point it happens; the gap is
purely that those numbers are never handed to the registry.

This change closes that gap with the smallest diff that does it, reusing the
exact pattern `add-curation-metrics` established: give each seam a nullable
handle to the existing registry (the same shape as the log writer and the
curation-run recorder), and let it record its own operation at the one
chokepoint. It depends only on already-built, unchanged capabilities — it reads
state each seam already computes and writes to the same registry `/metrics`
already renders.

## Goals / Non-Goals

**Goals:**
- A `server` metrics registry that, beyond the existing request-plane trio and
  curation-run counters, also exposes a per-kind EPUB-generations counter
  (`curation_epub_generations_total{kind}`) and the `pi`-evaluation families:
  `curation_pi_evaluations_total` (counter),
  `curation_pi_evaluations_failed_total` (counter), and
  `curation_pi_evaluation_duration_seconds` (histogram) — each rendered on
  `GET /metrics`, at zero before any activity.
- A `longevity` evaluator that records, per actual `pi` invocation (a cache
  miss), the evaluation count, the invocation latency, and a failure when the
  invocation errors or yields an unparseable (`unknown`) label; a cache hit
  records nothing. Recording goes into an injected, nullable registry and is
  non-fatal.
- A `download` resolver that records one EPUB generation labeled by the resolved
  `kind` on every non-empty resolve; a nothing-new resolve records nothing.
  Recording goes into an injected, nullable registry and is non-fatal.
- The two call sites that already hold the `*Metrics` (`server`'s download path,
  `curation-job`'s classify call) pass it through.
- Self-checks under `zig build test` for the new registry families and the two
  seams' record-on-operation behavior; `openspec validate
  add-longevity-download-metrics` passes.

**Non-Goals:**
- No persistent metrics and no metrics retention across restart. Metrics stay
  in-memory process state, consistent with the existing counters and uptime
  gauge (a scraper handles counter resets via `increase()`/`rate()`).
- No `pi`-evaluation-by-`kind` split. `kind` is the *output* of a
  classification, not known until after the invocation; labeling the call by its
  result kind would be semantically wrong and adds no diagnostic the per-kind
  *curated* counter does not already give.
- No EPUB-build-duration histogram. US-006 asks for EPUB *generations* per kind
  (a count), not build latency; add a duration histogram only if build-time
  distribution ever matters.
- No per-source, per-prompt, or per-tag cardinality on any new family —
  unbounded. The only label is `kind` on the EPUB-generation counter (two
  series), exactly as `add-curation-metrics` limited `kind` to the curated
  counter.
- No new HTTP route or status code; no auth, token, EPUB-structure, store,
  config, eval-cache, or record-format change; no new dependency; no change to
  the one-run-at-a-time serialization or the failure-tolerance/fallback
  behavior of the evaluator.

## Decisions

### D1 — One change for both deferred families, not two

`add-curation-metrics` deferred EPUB-generation and `pi`-evaluation metrics
together, as a single named follow-up. They share one mechanism — thread a
nullable registry handle (and, for latency, a monotonic clock read) into a seam
and record at the chokepoint. Splitting them into two changes would double the
proposal/design/tasks overhead for the same pattern and leave US-006 half-closed
longer. One change it is.

### D2 — An "evaluation" is an actual `pi` invocation, not a cache hit

US-006 says "`pi` evaluations." A cache hit never invokes `pi` — it is a cheap
local lookup, not a model call. Recording it as an "evaluation" would conflate
"we had the answer cached" with "we asked the model," hiding exactly the signal
the metric exists for (model cost and health). So count, latency, and failure
are recorded only on the cache-miss invoke path inside `classify`, after the
cache lookup misses and before control returns. This makes the counter read "how
many times did we actually call `pi`," which is the diagnostic an unattended
operator wants. The curated-items-per-kind counter (already exposed) covers
total throughput; this counter covers model load.

### D3 — A "failure" is an invoke error OR an unparseable (`unknown`) result

Both mean "`pi` did not yield a usable label": the binary could not be started,
exited non-zero, timed out, or returned prose that does not parse to
`short_term`/`long_term`. In every such case the evaluator already falls back to
the configured default `Kind` (failure tolerance, unchanged) and does not cache.
Counting these as one `failed` counter — rather than two — matches how the
operator reasons ("how often did the classifier flake?") and keeps the family
set small. The fallback `Kind` is unchanged; only the counter moves.

### D4 — Latency is a histogram reusing the existing bucket machinery, one unlabeled series

The registry already renders an HTTP request-latency histogram with fixed
buckets (`buckets_seconds`) and a `findBucket` placement. The `pi`-evaluation
latency reuses that: store one `u64` latency sample (nanoseconds) per invocation
and aggregate it into a single histogram series at `render` time. There is no
label dimension — `kind` is the result, not a call property (Non-Goals), and
there is no method/path. One series, fixed cardinality.

`// ponytail: reuse the HTTP histogram's fixed buckets for pi latency; tune
// buckets when real model-latency distribution is known (model calls are
// typically 1-3 orders of magnitude slower than a local HTTP route).`

### D5 — The registry stays in `server`; each seam takes an injected, nullable handle

The registry is owned by the `server` capability (it owns `/metrics`), exactly
as in `add-curation-metrics`. The `longevity` evaluator and the `download`
resolver each take an optional `metrics: ?*metrics_mod.Metrics` — nullable so
library callers and hermetic unit tests pass `null` and stay dependency-free,
identical to how the evaluator already takes its log writer and how the
curation run already takes its recorder. A `null` handle records nothing.

`// ponytail: concrete `*metrics_mod.Metrics` handle rather than a vtable seam;
// upgrade to an injected `Recorder` interface only if a second metrics backend
// (e.g. an OpenMetrics/OTLP exporter) is needed — same ceiling as
// add-curation-metrics D2.`

### D6 — Record inside the seam, not at the caller

Both `download.resolve` (called only from `server.resolveAndRespond`) and
`longevity.classify` (called only from `curation_job.run`) are the single points
through which every download and every classification flow. Recording inside
each seam — not at each caller, not in a wrapper — covers every caller
uniformly, never double-counts, and keeps the caller signatures unchanged. This
mirrors `add-curation-metrics` D3 (record inside `run`, not at the callers) and
`add-retention` (prune inside `run`) for the same single-chokepoint reason.

### D7 — Counters are monotonic cumulative sums, reset on restart

Each new counter (`epub_generations_total` per kind, `pi_evaluations_total`,
`pi_evaluations_failed_total`) is a cumulative `u64` that only increases across
operations in a process lifetime and resets to zero on restart — identical to
the existing curation-run counters and request counter. No rate calculation or
persistence in-process; the scraper computes rates. Consistent with the rest of
the registry; needs no new storage.

### D8 — EPUB-generation is labeled by `kind`; `pi`-evaluation is not

US-006 explicitly requires EPUB generations "per kind," and the resolver knows
its kind before it builds (it is the token's kind), so the
`curation_epub_generations_total` counter carries a `kind` label (`"news"` /
`"knowledge"`) — two series. The `pi`-evaluation families carry no label: the
call is not kind-scoped at invocation time, and labeling by *result* kind would
be misleading (Non-Goals). This keeps every new family at fixed, tiny
cardinality.

## Risks / Trade-offs

- **US-006 is now closed, not merely advanced.** Every operation the story names
  is exposed on `/metrics`. An operator scraping after this change can see
  download-side health (are EPUBs being generated, and for which kind) and
  classifier-side health (is `pi` being called, how fast, how often it fails),
  in addition to the curation-run and request-plane health already present.
- **One extra monotonic clock read per `pi` invocation.** A single
  `std.time`/`io` monotonic read around `invoker.call`. Negligible next to a
  model round-trip; no clock is read on the cache-hit path or on the
  nothing-new resolve path.
- **Histogram and counter cardinality is bounded.** The `pi`-evaluation
  histogram is one unlabeled series; the EPUB-generation counter has the `kind`
  label (two series); the two `pi` counters have no label. No per-source,
  per-prompt, or per-item cardinality (Non-Goals). Five new registry fields plus
  one latency sample list — negligible memory.
- **Coupling `longevity` and `download` to the `server` metrics module.** Both
  now import `metrics_mod`. The module is a plain counter/histogram bag with no
  serving, scheduling, or I/O of its own, so the dependency does not pull server
  concerns into either seam. D5's nullable handle keeps unit tests decoupled. If
  the registry ever gains serving-internal state, the D5 ceiling (an injected
  `Recorder` interface) is the upgrade path — the same one `add-curation-metrics`
  flagged for `curation-job`.
- **Counters reset on restart.** Cumulative counters start at zero on every
  process start; a `increase()`-based dashboard spans restarts only if the
  scraper handles counter resets (Prometheus does). Consistent with the existing
  counters; no regression.
