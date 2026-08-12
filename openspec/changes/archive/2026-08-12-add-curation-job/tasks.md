## 1. Config: feed sources and schedule (server-owned config)

- [ ] 1.1 In `src/config.zig`, add `pub const Source = struct { name: []const u8, url: []const u8 };`
  and `Config` fields `sources: []const Source = &.{}` and
  `schedule: []const u8 = "04:00"`. Deep-own them in `load` (dupe `schedule`;
  `copySources`/`freeSources` mirroring the filter/tag rule helpers) and free
  them in `deinit` (design D2; spec: JSON configuration loading).
- [ ] 1.2 Self-check (config): a config with a `sources` list of
  `{name,url}` objects parses into owned `Source` records; an absent `sources`
  yields an empty list; an absent `schedule` yields `"04:00"`; unknown fields
  are still ignored; an existing config without the new fields still loads
  unchanged (spec: JSON configuration loading).

## 2. `curation-job` capability

- [ ] 2.1 Add `src/curation_job.zig`. Define a `Summary` struct
  (`sources`, `fetched`, `curated`, `news`, `knowledge`, `failed_sources`) and a
  `RunOutcome` enum union of `.ran(Summary)` and `.busy` (design D3; spec: One
  run at a time).
- [ ] 2.2 Implement the synchronous `run` taking injected dependencies (the
  configured feed sources, `Rules`, `longevity.PiConfig`, a `*std.http.Client`,
  a `*longevity.EvalCache`, a `longevity.Invoker`, a `*Store`, a user-agent, a
  fetch timeout, and a `*std.Io.Writer` for logs). For each source: call
  `fetch.acquireFeed`; on error log a structured `curation.source_failed` line
  and increment `failed_sources`, continuing to the next source; on success
  collect the items. Then run `curation.curate(gpa, all_items, rules)`; for each
  survivor call `longevity.classify(...)` to get a `Kind` and
  `store.append(kind, survivor)`, incrementing the per-kind counter. Free
  intermediates with the existing `freeParsed`/`freeCurated` helpers. Return the
  `Summary` (design D1, D7, D8; spec: One curation run, Per-source error
  isolation).
- [ ] 2.3 Implement `tryRun` with the same inputs: guard a `std.Thread.Mutex`
  with `tryLock`; on failure return `.busy` (no fetch, no classify, no append);
  on success run `run` under the lock and return `.ran(summary)` (design D3;
  spec: One run at a time).
- [ ] 2.4 Self-check (job): with a stubbed `longevity.Invoker` returning
  deterministic kinds and a temp `Store`, a run over two in-process "sources"
  (drive `run` directly with a stubbed acquisition seam, or stub the fetch via
  an injectable acquire function) stores each survivor under its classified kind
  and the summary counts match; a `cap` of `2` over five survivors stores at most
  two; a failing source increments `failed_sources` and the run continues; a
  `pi` failure (stub returns garbage) stores the survivor under the fallback
  kind and is not counted as a failed source. Assert `tryRun` returns `.busy`
  and appends nothing when the mutex is already held (design D3, D8; spec: One
  curation run, Per-source error isolation, One run at a time).

## 3. Thread-safe store (storage)

- [ ] 3.1 In `src/store.zig`, add a `mutex: std.Thread.Mutex = .{}` field to
  `Store` and lock it for the duration of `append` and of `range` (covering
  `records`, the per-kind id lists, and `next_id`). Change `range`'s receiver to
  `*Store` (design D5; spec: Concurrent append and range access).
- [ ] 3.2 Self-check (store): spawn one writer thread appending `news` records
  and one reader thread calling `range(.news, 0)` concurrently; assert both
  finish, the reader only ever sees fully-indexed records, and `zig build test`
  is race-clean (run under `ThreadSanitizer` if available in the toolchain)
  (spec: Concurrent append and range access).

## 4. `POST /curate` route (server)

- [ ] 4.1 In `src/server.zig` `handleRequest`, add a `POST /curate` branch that
  is protected (`open_route = false`): missing/wrong bearer → `401` (auth-first,
  before any run). On valid auth, call `curation-job.tryRun`; `.ran(summary)` →
  `200` with `Content-Type: application/json` and the summary serialized via
  `std.json`, no `X-Next-Token`; `.busy` → `409 Conflict` empty body
  (design D6; spec: Curate endpoint).
- [ ] 4.2 Self-check (route handler): `POST /curate` with valid bearer and no
  run in progress returns `200 application/json` (assert the JSON parses and
  carries the summary keys); a second `POST /curate` while busy returns `409`
  with empty body; missing/wrong bearer returns `401` before any run; `GET /curate`
  is not matched by this branch (spec: Curate endpoint).

## 5. Daily scheduler (server)

- [ ] 5.1 In `src/server.zig`, construct the process-lifetime shared resources
  in `serveCommand` after the store loads: a `std.http.Client`, and a
  `longevity.EvalCache` loaded from `longevity.defaultCachePath`; pass them (plus
  `*Store`, now mutable, `cfg`, and `productionInvoker`) to both the route and
  the scheduler. Deinit them on shutdown (design D8).
- [ ] 5.2 Add a scheduler thread started in `serveCommand` (alongside the accept
  loop) that loops: compute the duration to the next `cfg.schedule` local time;
  sleep in ≤1s increments re-checking the existing `stop_flag` each iteration;
  at the scheduled minute call `tryRun` — `.busy` → log a structured
  `curation.skipped_busy` line; `.ran` → log a `curation.run` summary line;
  repeat. Join the thread on shutdown (design D4; spec: Daily scheduler).
- [ ] 5.3 `// ponytail: single fixed daily time, 1s shutdown poll, no jitter,
  // backoff, or catch-up for missed ticks; revisit if the schedule model grows.`
  (design D4).

## 6. Integration

- [ ] 6.1 Register `src/curation_job.zig` in `main.zig`'s comptime test import
  block so `zig build test` discovers it.
- [ ] 6.2 `zig build test` green; `openspec validate add-curation-job` passes.
