## 1. Age-based prune in the store (storage capability)

- [x] 1.1 In `src/store.zig`, add a private `parseDateEpoch(date: []const u8)
  ?i64` that returns epoch seconds for ISO-8601 / RFC-3339
  (e.g. `2024-01-01T00:00:00Z`) and RFC-822
  (e.g. `Mon, 01 Jan 2024 00:00:00 GMT`), and `null` for empty or any other
  format. Use `std.time` calendar helpers where possible; no allocation
  (design D2; spec: Age-based retention prune).
- [x] 1.2 Add `pub fn pruneByAge(self: *Store, now_epoch_seconds: i64,
  max_age_seconds: i64) PruneError!usize`. It locks the store mutex for its
  whole duration; computes `cutoff = now_epoch_seconds - max_age_seconds`;
  collects the records whose `parseDateEpoch(date)` is non-null and `< cutoff`
  as pruned; rewrites the surviving records to a sibling temp file
  (`<path>.tmp.<pid>` or similar in the same dir) via `std.json`, then atomically
  replaces the store file (`std.Io.Dir.rename` / `renameW` on the temp over the
  path); rebuilds `self.records`, `self.news_ids`, `self.knowledge_ids` from the
  survivors (freeing pruned records with `freeRecord`); leaves `self.next_id`
  unchanged; returns the pruned count. On any I/O or alloc error it restores the
  in-memory state and propagates the error without leaving the temp file in
  place (design D1, D2, D3; spec: Age-based retention prune).
- [x] 1.3 Define `PruneError` as `std.mem.Allocator.Error ||
  std.Io.File.OpenError || std.Io.File.WriteError || std.Io.File.RenameError ||
  std.Io.Writer.Error` (or the project's existing `std.Io`-equivalent set, mirroring
  `AppendError`).
- [x] 1.4 Self-check (store): build a `Store` on a temp path with records dated
  100 and 10 days before a fixed `now`, an empty-date record, and an
  unparseable-date record; assert `pruneByAge(now, 90*86400)` returns `1`,
  removes only the 100-day record, keeps the rest, and leaves `next_id`
  unchanged. Also assert two equally-old records dated
  `2024-01-01T00:00:00Z` and `Mon, 01 Jan 2024 00:00:00 GMT` are both pruned
  (design D2; spec: Age-based retention prune).
- [x] 1.5 Self-check (store): after a prune, reload the store from the same path
  (`Store.load`) and assert it holds exactly the survivors in ascending id order
  with no pruned record (design D3; spec: Age-based retention prune).
- [x] 1.6 Self-check (store): assert a record appended after a prune that freed
  id `2` receives the next monotonic id (not `2`), confirming ids are never
  reused (design D3; spec: Age-based retention prune).

## 2. Prune after a run (curation-job capability)

- [x] 2.1 In `src/curation_job.zig`, add `retention_days: u32` as a trailing
  parameter to `run` and to `tryRun` (after the existing web/Lightpanda params),
  and a `pruned: usize = 0` field on `Summary` (design D4, D5; spec: One
  curation run).
- [x] 2.2 In `run`, after the survivor-append loop and before returning the
  summary, if `retention_days > 0`: read `now` once via `std.time` (epoch
  seconds), call `store.pruneByAge(now, @as(i64, retention_days) * 86400)`, and
  on success set `summary.pruned` to the returned count; on a prune error log a
  structured `curation.prune_failed` line at ERROR and leave `summary.pruned` at
  `0` (a prune failure does not abort the run — survivors are already stored).
  When `retention_days == 0`, skip the prune call entirely (design D4, D5, D6;
  spec: One curation run).
- [x] 2.3 Propagate `retention_days` through `tryRun` into the internal `run`
  call (design D4; spec: One curation run).
- [x] 2.4 Self-check (job): with a stubbed acquire + pi, seed a temp store with
  one record dated ~100 days ago (year 2000 ISO-8601) and one dated via the same
  `std.time` source the run uses (recent); run with `retention_days = 90`; assert
  the old record is gone, the recent record remains, and the returned summary
  reports `pruned == 1` (design D4, D6; spec: One curation run).
- [x] 2.5 Self-check (job): run with `retention_days = 0` over a store holding
  a year-2000 record; assert nothing is pruned and `summary.pruned == 0`
  (design D5; spec: One curation run).
- [x] 2.6 Self-check (job): an empty-source run with `retention_days = 90` over
  a store holding an old record still prunes it and reports `pruned` (design D4;
  spec: One curation run).

## 3. Config field + wiring (server capability)

- [x] 3.1 In `src/config.zig`, add `retention_days: u32 = 90` to the `Config`
  struct and set it in the `Config` literal inside `load` (`retention_days =
  cfg.retention_days`, mirroring the `cap` pattern; value type — no deep copy or
  free) (design D5; spec: JSON configuration loading).
- [x] 3.2 Self-check (config): a config omitting `retention_days` yields `90`;
  a config with `"retention_days":30` yields `30`; a config with
  `"retention_days":0` yields `0`; unknown fields are still ignored; an existing
  config without the field still loads unchanged (design D5; spec: JSON
  configuration loading).
- [x] 3.3 In `src/server.zig`, pass `deps.cfg.retention_days` to both `tryRun`
  call sites — the `POST /curate` handler (`handleCurate`) and the daily
  scheduler loop. No change to the route contract, status codes, auth ordering,
  or scheduler timing (design D1; spec: Curate endpoint, Daily scheduler).
- [x] 3.4 Self-check (route handler): a `POST /curate` with a valid bearer and
  stubbed acquisition still returns `200 application/json` whose body parses
  with the summary keys (now including `pruned`); a busy run still returns
  `409`; a missing/wrong bearer still returns `401` before any acquisition or
  prune (spec: Curate endpoint).

## 4. Integration

- [x] 4.1 No new module to register (prune lives in `store.zig`, already
  imported by `curation_job.zig` and registered in `main.zig`'s test block).
- [x] 4.2 `zig build test` green; `openspec validate add-retention` passes.
