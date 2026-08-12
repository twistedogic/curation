## Context

`curation` has, after seven archived changes, every piece except the one that
connects them. `add-server` gave the HTTP surface, config, `/healthz`, the
bearer gate, structured logging, `/metrics`, and graceful SIGINT shutdown.
`add-curation-pipeline` gave the pure `curation.curate` (normalize → dedupe →
filter → tag → cap), a pure function of `(items, rules)`. `add-feed-fetching`
gave `fetch.acquireFeed` (fetch + parse one feed, error per source).
`add-longevity-evaluator` gave `longevity.classify` (cache → render → invoke
`pi` → parse → fallback to the configured default kind; never errors).
`add-storage` gave the append-only JSONL store with global monotonic ids and a
half-open `range(kind, since_id)`. `add-epub-download` gave the token codec,
the stdlib EPUB builder, the resolver, and the bearer-gated `GET /download`.
`add-download-ui` gave the embedded page and the first-download bootstrap.

What is missing is the caller. `curation.curate` stops at the cap and returns a
slice nobody consumes. `fetch.acquireFeed`, `longevity.classify`, and
`store.append` each have unit tests but no production caller. So the store stays
empty: `/download` returns `204` for every kind, the page always shows "nothing
new," and none of US-002's acceptance criteria hold. The `add-download-ui`
design said this plainly — "The store may be empty until then … a later
orchestration change."

`.see/intent.md` US-002 / FR-7 / Decision #8 fix the contract: a curation run
fetches/renders all configured sources, dedupes, filters, tags, caps, evaluates
longevity via `pi`, and splits survivors into the `news` and `knowledge`
streams; it runs both from a built-in daily scheduler (default 04:00 local) and
from a synchronous `POST /curate` (the canonical entry point for external cron
and manual runs). FR-5 fixes the stage order; FR-15 fixes the `pi` wrapper
(no provider/model/key in curation, cache on SHA-256, failure → `unknown` →
default kind, non-fatal). One misbehaving source must never abort the run.

This change builds exactly that: a new `curation-job` capability that composes
the four existing capabilities into one synchronous run, a `POST /curate` route
and a daily scheduler in `server`, the `sources`/`schedule` config fields server
already owed, and the store mutex `add-storage` explicitly deferred to "the
orchestration change." It depends only on already-built, unchanged capabilities.

## Goals / Non-Goals

**Goals:**
- A library-callable `curation-job` `run` that, for one pass: acquires every
  configured **feed** source (per-source error isolation — a failing source is
  skipped and counted, never aborts), runs the pure `curation` pipeline over the
  union, classifies each survivor's longevity via the `longevity` capability,
  and appends each survivor to the store under the returned `Kind`. Returns a
  summary struct.
- One-run-at-a-time serialization inside the capability (`tryRun`), so a
  scheduler tick and a `POST /curate` (or two `POST /curate`s) cannot append the
  same items twice.
- A bearer-gated `POST /curate` route: `200` + small JSON summary on success,
  `409 Conflict` when a run is in progress, `401` on auth failure (auth-first).
- A daily scheduler thread started by `serveCommand`, aligned to a configurable
  local time (default `04:00`), that calls `tryRun`, skips + logs on `busy`, and
  stops promptly with the server.
- `sources` (feed `{name,url}`) and `schedule` (`"HH:MM"`, default `"04:00"`)
  in the server-owned config schema, deep-owned like the other slice fields.
- A thread-safe store: an internal mutex serializing `append` and `range`.
- `zig build test` green.

**Non-Goals:**
- Lightpanda web-content rendering (US-008) — a later slice; this run acquires
  **feed** sources only. Web sources are deferred, not blocked (see D2).
- Extended curation/source/`pi` Prometheus metrics (US-006) — a separate slice;
  the job logs a structured summary line instead.
- Age-based retention / prune (FR-16) — a separate slice; the store grows until
  then.
- A persistent job queue, retry/backoff, or catch-up for missed schedule ticks
  (D4) — the scheduler runs at most once per tick, no later.
- A second EPUB or mixing kinds — exactly two streams, as today; the job only
  decides *which* of the two each survivor lands in.
- Changing the token/watermark mechanism — per-kind delivery is already
  correct: the job appends under a `Kind`, store ids are monotonic, and
  `/download`'s `(token, today]` range already delivers exactly the new items of
  that kind (D7). No watermark code is added.

## Decisions

### D1. A new `curation-job` capability owns the run; `server` owns the route, the scheduler, and the config fields
The run is business logic that composes four capabilities; serving, scheduling,
and config-loading are runtime concerns. This mirrors the established split:
the pure `download` engine is a capability and the `/download` *route* lives in
`server`; the pure `curation` pipeline is a capability and whatever calls it
lives elsewhere. So `curation-job` exposes a synchronous `tryRun`/`run` taking
injected dependencies (store, http client, eval cache, invoker, config), and
`server` adds the `POST /curate` route that calls it and spawns the scheduler
thread that calls it. Config is "the JSON file loaded by the server capability"
per every prior spec, so `sources`/`schedule` are added there. The scheduler is
lifecycle/timing → server.
- *Alternative:* fold the run into `server.zig`. Rejected — it would bury
  testable orchestration logic (per-source isolation, the split, serialization)
  inside the HTTP module and re-couple business logic to I/O wiring; the run is
  the unit worth testing in isolation.
- *Alternative:* make scheduling its own capability. Rejected — a timer thread +
  shutdown cooperation is lifecycle, which `server` already owns (SIGINT handler,
  accept loop, `stop_flag`).

### D2. Feed sources only this slice; web rendering (US-008) deferred; config models a feed source `{name, url}`, forward-compatible
`fetch.acquireFeed` already does fetch + parse for feeds; web rendering via
Lightpanda is a separate, explicitly-deferred slice (US-008) that needs a
subprocess render path this change does not build. So `sources` is a list of
feed sources `Source = { name, url }`, and the run acquires each as a feed.
This is forward-compatible: US-008 can extend the source model later
(e.g. an optional `type` field defaulting to `feed`, or a sibling `web_sources`
list) without breaking this loader, because unknown fields are already ignored
and the run only invokes the feed path. The intent's "sources (feed URLs, web
URLs)" is satisfied incrementally, the same way every prior change extended
config one slice at a time.
- *Alternative:* add a `type` discriminator and a Lightpanda stub now. Rejected —
  builds the US-008 surface before its slice; YAGNI until the render path exists.

### D3. One-run-at-a-time via a non-blocking `tryRun`; `POST /curate` → 409, scheduler → skip+log on `busy`
The pipeline dedupes *within* a run (by normalized URL/title hash) but never
*across* runs, so two concurrent runs would fetch the same items, classify them
again (wasting `pi` calls), and append them twice — corrupting the
"never a duplicate" §8 guarantee. The run is therefore serialized by a mutex
owned by the capability, exposed as `tryRun(...) -> .ran(Summary) | .busy`. Both
trigger paths use it: `POST /curate` maps `.busy` to `409 Conflict` (idempotent
for cron/operators, who retry); the scheduler maps `.busy` to a structured
`curation.skipped_busy` log line and waits for the next tick. No queueing, no
blocking — the simplest design that cannot double-append.
- *Alternative:* block the second caller until the first finishes. Rejected — a
  `POST /curate` could hang for the duration of a long run (many feeds + many
  `pi` calls); `409` is honest and cheap.
- *Alternative:* let runs overlap and dedupe across runs at append time.
  Rejected — that needs a persistent "already stored" index (URL/title → id) the
  store does not have, and re-spends `pi` on duplicates; serializing the run is
  strictly simpler and cheaper.

### D4. Scheduler = one background thread sleeping to the next local "HH:MM", polling `stop_flag` for prompt shutdown, no catch-up
A timer aligned to a configurable local time is all FR-7 asks. The thread loops:
compute the duration to the next `schedule` wall-clock time; sleep in short
increments (≤1s) re-checking `stop_flag` each iteration so SIGINT still shuts the
process down within ~1s; on the scheduled minute call `tryRun`; repeat. If the
process was down at 04:00, no run is "made up" — the next run is the next 04:00
(or a manual `POST /curate`). This is the laziest faithful scheduler.
`// ponytail: single fixed daily time, 1s shutdown poll, no jitter/backoff, no
// catch-up for missed ticks; revisit if the schedule model grows (multiple
// times, intervals, catch-up).`
- *Alternative:* a cron expression library. Rejected — a dependency and a richer
  model than "once a day at HH:MM".
- *Alternative:* sleep the full duration in one `nanosleep`. Rejected — the
  process would not respond to SIGINT until the sleep elapses (could be hours);
  the short-poll loop keeps shutdown responsive at trivial cost.

### D5. Store mutex serializing `append` and `range`; server holds `*Store`
Once the job runs on a scheduler thread (or the `POST /curate` request thread)
while the serving thread serves `/download`, the store has one writer and one or
more readers concurrently. `store.zig` already says so:
"Single-threaded store until a concurrent caller lands; guard append + index
with a mutex in the orchestration change." This change adds a
`std.Thread.Mutex` to `Store`, locked for the duration of `append` (which mutates
`records`, the per-kind id lists, and `next_id`) and of `range` (which slices
those lists). Because `range` now locks, it takes a mutable `*Store`; the server
threads therefore hold `*Store` (not `*const Store`). The file format, id
semantics, and half-open range semantics are unchanged.
- *Alternative:* a reader/writer lock. Rejected — one writer at digest volume;
  a plain mutex is simpler and correct, and the §7 ceiling (SQLite) is the real
  upgrade path, not a finer-grained lock.
- *Alternative:* copy-on-write snapshots for readers. Rejected — far more
  machinery than a mutex for no measurable benefit at this volume.

### D6. `POST /curate` runs synchronously on the request thread; minimal stable JSON summary; auth-first
The route runs the job inline and returns when it finishes. A run is bounded by
config (number of sources × items, the per-run `cap`, and `pi` calls only for
uncached survivors), so synchronous is acceptable for an operator/cron endpoint
and avoids a result-store or polling protocol. The `200` body is a small JSON
object with stable keys (e.g. `sources`, `fetched`, `curated`, `news`,
`knowledge`, `failed_sources`). Authentication precedes resolution exactly as
`/download` does: a missing/wrong bearer returns `401` before the job is
considered.
- *Alternative:* accept the request, run async, return `202` + a job id the
  client polls. Rejected — a job store and a status endpoint for a daily task;
  YAGNI until a run is too slow to wait on.

### D7. Per-kind watermarks advance implicitly via store ids; no watermark code is added
US-002 says "each kind's high-water mark advances only over items of that kind
actually delivered." The delivery mechanism already does this: a token is
`base64("<kind>:<id>")`, the store assigns strictly-increasing global ids, and
`/download`'s resolver returns the half-open range `(token.id, today]` of *that*
kind. The job only appends each survivor under the `Kind` the classifier
returned; it touches no watermark, no token, and no download code. New items of a
kind therefore appear in that kind's next download and in no other — the §8
guarantee — for free.
- *Alternative:* maintain an explicit per-kind high-water mark the job advances.
  Rejected — redundant with the store's monotonic ids and the token codec;
  duplicates state the download engine already owns.

### D8. The job injects the `pi` invoker and the eval cache; production wires `productionInvoker`, tests wire a stub
`longevity.classify` already takes an `Invoker` seam and a `*EvalCache`, and its
tests stub the invoker. The job takes both as parameters (plus the shared
`std.http.Client` and the config), so the job's own tests inject a stub invoker
returning deterministic kinds and never spawn `pi`. Production (`serveCommand`,
and thus both the scheduler and `POST /curate`) wires `longevity.productionInvoker`
and one `EvalCache` loaded from `$XDG_CACHE_HOME/curation/eval-cache.json`, kept
for the process lifetime. No new credential or model config is introduced — the
`pi` object in config already carries path/model/prompt/default_kind.
- *Alternative:* have the job construct its own client/cache. Rejected — they are
  process-lifetime resources (connection pool, persistent cache); constructing
  them per run would drop the cache on every run and re-dial.

## Risks / Trade-offs

- **[Concurrent runs double-append]** → Mitigated (D3): `tryRun` serializes; a
  busy caller gets `409` (POST) or skips (scheduler), so two runs never overlap.
- **[Scheduler thread + serving thread race the store]** → Mitigated (D5): the
  store mutex serializes `append` and `range`.
- **[A long run blocks a `POST /curate` request]** → Accepted (D6): runs are
  config-bounded; synchronous is fine for an operator/cron endpoint. The `409`
  path keeps a second caller from piling on.
- **[A misbehaving source aborts the run]** → Mitigated by design:
  `fetch.acquireFeed` returns an error per source; the run logs it, counts it in
  `failed_sources`, and continues (intent US-002, FR-3).
- **[A `pi` failure aborts the run]** → Mitigated by the existing
  `longevity.classify` contract: it never returns an error, only a `Kind`
  (fallback to the configured default, logged). The run is unaffected.
- **[Missed schedule ticks are not made up]** → Accepted (D4): if the process is
  down at 04:00, the next run is the next 04:00 (or a manual `POST /curate`).
  Acceptable for a single-user daily digest.
- **[Web-content sources are not yet fetched]** → Accepted (D2): this slice is
  feeds only; the intent's web sources arrive with US-008. A config with web
  URLs is simply not acquired until then (no error, just ignored-by-absence).

## Migration Plan

Greenfield and additive — no migration. Deploy by: nothing required at startup
beyond the existing config; `POST /curate` appears (bearer-gated) and the daily
scheduler starts alongside the accept loop. The store gains an internal mutex
transparently. Existing config files without `sources`/`schedule` parse as
before (empty source list, default `04:00`); a deployment that wants content
adds feed sources to config and either waits for 04:00 or sends one
`POST /curate`. No change to `/download`, `/healthz`, `/metrics`, `GET /`, the
store file format, or tokens. Rollback is `git revert` (`POST /curate`
disappears, the scheduler thread is gone, the store mutex becomes uncontended,
and `/download` behavior is unchanged).

## Open Questions

- None blocking. The exact JSON key set of the `POST /curate` summary is an
  implementation detail; the keys named in D6 are the starting set and are
  treated as stable once shipped. If an operator ever needs run history or
  last-run status in the UI, that is a follow-up (the UI change is archived);
  it needs no change to the job contract beyond surfacing the summary struct.
