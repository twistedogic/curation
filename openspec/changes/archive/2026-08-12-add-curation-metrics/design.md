## Context

`curation` runs unattended: a daily scheduler and `POST /curate` both drive one
end-to-end curation run (`add-curation-job`), which acquires feed and web
sources, runs the deterministic pipeline, classifies each survivor's longevity
via `pi`, appends survivors to the JSONL store under their `Kind`, and prunes
old records by age (`add-retention`). The `server` capability (`add-server`)
owns config, the bearer gate, the routes, and a metrics registry exposed at
`GET /metrics`.

The registry that exists today is deliberately minimal. `src/metrics.zig` holds
an `observations` list of `(method, path, latency_ns)` and `render` emits three
families: `curation_http_requests_total` (counter), the
`curation_http_request_duration_seconds` histogram (fixed buckets, per
method+path), and `curation_uptime_seconds` (gauge). The `server` spec's
"Prometheus metrics endpoint" requirement blessed exactly that "initial metric
set" and stopped there. So today's `/metrics` answers "did the server handle
traffic?" but never "did curation run, did sources fail, did anything get
curated?" — which is the question that actually matters for an unattended
digest server.

The intent calls for the rest as a numbered story. `.see/intent.md` **US-006**
requires Prometheus metrics over "curation runs, items fetched/items curated
per kind, source fetch errors, EPUB generations per kind, `pi` evaluations
(count/latency/failures), request counts/latency"; **FR-11** requires metrics
"on the operations above"; **§2 principle 5** requires Prometheus metrics "from
day one" and **AGENTS.md** requires a Prometheus scrape endpoint for servers.
The run already computes every curation number and returns it in its `Summary`
(`sources`, `fetched`, `curated`, `news`, `knowledge`, `failed`, `pruned`). The
gap is purely that those numbers are never handed to the registry.

This change closes the bulk of that gap with the smallest diff that does it:
extend the registry with the curation counters, give the run a handle to it
exactly like it already takes a log writer, and let the run record its own
summary at the one chokepoint both callers funnel through. It depends only on
already-built, unchanged capabilities — it reads the same `Summary` the run
already returns and writes to the same registry `/metrics` already renders.

## Goals / Non-Goals

**Goals:**
- A `server` metrics registry that, beyond the existing request counter, latency
  histogram, and uptime gauge, also exposes curation counters: total runs, total
  items fetched, total items curated (labeled `kind="news"`/`kind="knowledge"`),
  total source fetch errors, and total items pruned — each a Prometheus counter
  family rendered on `GET /metrics`.
- A `curation-job` run that records its run summary into an injected registry
  at the end of a run that executed (never on a `.busy` probe), with recording
  failures logged and non-fatal.
- The two `tryRun` call sites (`POST /curate`, daily scheduler) pass the
  registry they already hold.
- Self-checks under `zig build test` for the new registry families and the job's
  record-after-run behavior; `openspec validate add-curation-metrics` passes.

**Non-Goals:**
- No per-kind **EPUB generations** metric and no **`pi` evaluation
  count/latency/failures** metric in this slice. Those require threading the
  registry (and a latency timer) into the `download` and `longevity` seams and
  are a separate follow-up change. US-006 is advanced, not closed, by this
  change.
- No histograms for curation-run duration or items-per-run in this slice —
  counters over the summary fields are the lazy complete answer for "is curation
  healthy"; add a duration histogram if run-time distribution matters.
- No persistent metrics, no metrics retention across restart, no histograms
  beyond the existing request-latency one. Metrics stay in-memory process state,
  consistent with the existing request counter and uptime gauge.
- No new HTTP route or status code; no auth, token, EPUB, store, config, or
  record-format change; no new dependency; no change to the one-run-at-a-time
  serialization.

## Decisions

### D1 — Counters over the run `Summary`, not a new capability

The run already returns a `Summary` carrying `sources`, `fetched`, `curated`,
`news`, `knowledge`, `failed`, and `pruned`. Recording those as Prometheus
counters is a direct, one-call-site mapping. A separate `observability`
capability would be a one-implementation wrapper around the registry and the
job; that is exactly the unrequested abstraction to avoid. The registry stays in
the `server` capability (it owns `/metrics`), and the run records into it. No
new capability is introduced.

### D2 — The registry is an injected, nullable handle, mirroring the log writer

The `curation-job` capability already takes a log writer as an injected
dependency and writes structured lines to it. The metrics registry is the same
shape of concern — an observability sink. The run therefore takes an optional
`metrics: ?*metrics_mod.Metrics` (nullable so library callers and unit tests can
pass `null`). At the end of `run` (the body that executes only when a run is not
busy), if the handle is non-null, the run calls the registry's recording methods
once, feeding them the summary fields it already holds. A `null` handle records
nothing — this keeps the job's pure-logic unit tests hermetic and dependency-free
exactly as they are today.

`// ponytail: concrete `*metrics_mod.Metrics` handle rather than a vtable seam;
upgrade to an injected `Recorder` interface only if a second metrics backend
(e.g. an OpenMetrics/OTLP exporter) is needed.`

### D3 — Record inside `run`, not at the caller

Both `POST /curate` and the daily scheduler route through `tryRun`, and `tryRun`
delegates the real work to `run` only when no run is in progress (`.busy`
performs no work). Recording at the end of `run` — not at each caller, not in
`tryRun`'s busy branch — guarantees exactly one recording per executed run,
covers both call sites uniformly, and never double-counts. This mirrors how
`add-retention` placed the prune at the end of `run` for the same single-source
reason.

### D4 — Counters are monotonic cumulative sums, reset on restart

Each curation counter is a cumulative `u64` that only increases across runs in a
process lifetime (runs, items fetched, items curated per kind, source errors,
items pruned). A scrape sees the running totals. On restart they reset to zero,
identical to the existing request counter and uptime gauge. There is no rate
calculation or persistence in-process; the scraper (Prometheus) computes rates
via `increase()`/`rate()`. This matches how the existing request counter behaves
and needs no new storage.

### D5 — One counter family per concept; `kind` is the only label

The five counters map one-to-one to summary fields, keeping the exposition
predictable. The only label is `kind` on `curation_items_curated_total`
(`"news"` / `"knowledge"`) — the per-kind split US-006 explicitly requires and
that the `Summary` already separates (`news`, `knowledge`). No `method`/`path`
labeling on the curation counters (those belong to the request counter), and no
per-source or per-tag cardinality, which would be unbounded.

### D6 — Recording failures are non-fatal

The run's primary job is to curate and store survivors. A recording failure
(allocator error appending to the registry) is logged at WARN via the existing
structured log writer and swallowed; it never propagates to the caller and never
aborts the run. A missed metric is a degraded dashboard, not a missed digest.
This matches the project's established failure-tolerance stance (per-source
errors, `pi` failures, prune failures are all non-fatal).

## Risks / Trade-offs

- **US-006 is advanced, not closed.** EPUB-generations-per-kind and
  `pi`-evaluation count/latency/failures are deferred to a follow-up (Non-Goals).
  An operator scraping `/metrics` after this change sees curation health but not
  download- or classifier-side health. Flagged explicitly so US-006 is not
  treated as done; the follow-up change is the obvious next slice.
- **Counters reset on restart.** Cumulative counters start at zero on every
  process start, so a `increase()`-based dashboard spans restarts only if the
  scraper handles counter resets (Prometheus does). Consistent with the existing
  request counter; no regression. Flagged `ponytail:` only if long-term
  historic accuracy across restarts is ever required.
- **Registry grows by five counters in memory.** Five `u64`s plus their static
  exposition text — negligible, and fixed cardinality (D5). No allocation per
  run beyond the optional recorder indirection.
- **Coupling the job to the `server` metrics module.** `curation_job.zig`
  imports `metrics_mod`. The module is a plain counter bag with no serving,
  scheduling, or I/O of its own, so the dependency does not pull server concerns
  into the job. D2's nullable handle keeps unit tests decoupled. If the registry
  ever gains serving-internal state, the D2 ceiling (an injected `Recorder`
  interface) is the upgrade path.
