## 1. Config: web sources and Lightpanda (server-owned config)

- [ ] 1.1 In `src/config.zig`, add a `DumpFormat` enum (`markdown`, `html`) and
  `pub const LightpandaConfig = struct { path: []const u8 = "lightpanda",
  dump_format: DumpFormat = .markdown };`. Add `Config` fields
  `web_sources: []const Source = &.{}` and `lightpanda: LightpandaConfig = .{}`
  (design D6; spec: JSON configuration loading).
- [ ] 1.2 Deep-own them in `load`: dupe `lightpanda.path` (mirror the `pi.path`
  pattern) and `copySources(gpa, cfg.web_sources)` for `web_sources`; free them
  in `deinit` (`freeSources(gpa, cfg.web_sources)` + `gpa.free(cfg.lightpanda.path)`).
  `dump_format` is an enum, so no allocation (design D6; spec: JSON configuration
  loading).
- [ ] 1.3 Self-check (config): a config with a `web_sources` list of `{name,url}`
  objects parses into owned `Source` records; an absent `web_sources` yields an
  empty list; an absent `lightpanda` block yields `path="lightpanda"` and
  `dump_format=.markdown`; a custom `lightpanda` block (`{"path":"/opt/lp",
  "dump_format":"html"}`) is parsed and owned; unknown fields are still ignored;
  an existing config without the new fields still loads unchanged (spec: JSON
  configuration loading).

## 2. `render` acquisition path (sources capability)

- [ ] 2.1 Add `src/render.zig`. Import `item_mod` and re-export `Item`. Define
  `acquireWeb(gpa, io, source_url, source_name, lightpanda:
  config_mod.LightpandaConfig, timeout) anyerror![]Item` that spawns the
  Lightpanda child process via `std.process.Child` with argv
  `{ lightpanda.path, "fetch", "--dump", @tagName(lightpanda.dump_format),
  source_url }`, captures stdout into an allocating writer bounded by `timeout`,
  and on a zero exit with non-empty stdout returns a one-element `Item` slice:
  `title = source_name`, `url = source_url`, `body = <captured output>`,
  `date = ""`, `source = source_name` (design D1, D2, D5; spec: Web-content
  acquisition via Lightpanda).
- [ ] 2.2 On any failure — binary not found, non-zero exit, timeout, or empty
  captured stdout — `acquireWeb` returns an error (the `config_mod.Source`-
  shaped error set union) and frees any partial allocation; it never terminates
  the process and performs no HTTP request or feed parsing of its own (design D3,
  D5; spec: Web-content acquisition via Lightpanda).
- [ ] 2.3 Self-check (render): with a stubbed/known-binary path, assert (a) a
  zero-exit subprocess printing `# Hi\n\nbody` yields exactly one item whose
  `body` is that output, `url` is the source URL, and `title`/`source` are the
  source name; (b) a non-existent binary path returns an error and no items; (c)
  a non-zero exit returns an error and no items. Use a tiny helper script or the
  real `lightpanda` only when present; otherwise drive the child-spawn path with
  a `/bin/sh -c`-equivalent stub so the test is hermetic (design D2, D5; spec:
  Web-content acquisition via Lightpanda).

## 3. Acquire web sources in the run (curation-job)

- [ ] 3.1 In `src/curation_job.zig`, add a `WebAcquireFn = *const fn(
  gpa, io, source_url, source_name, lightpanda: config_mod.LightpandaConfig,
  timeout) anyerror![]Item` seam. Add `web_sources: []const Source`, a
  `lightpanda: config_mod.LightpandaConfig`, and `web_acquire: WebAcquireFn`
  parameters to `run` and to `tryRun` (design D4; spec: One curation run).
- [ ] 3.2 In `run`, after the feed-source loop, iterate `web_sources` calling
  `web_acquire(...)` with the same per-source isolation: on error log a
  structured `curation.source_failed` line and increment `failed_sources`,
  continuing; on success append the item(s) into the existing `flat_items` union
  (and keep them alive for the pipeline via the existing `acquire_results`
  defer, freeing web items with the same helper feed/parsed freeing uses — note
  web items are `Item`s allocated by `render`, freed like parsed items). Count
  web sources into `summary.sources` (design D3, D4; spec: One curation run,
  Per-source error isolation).
- [ ] 3.3 Self-check (job): extend the stubbed-acquire test harness with a
  `web_acquire` stub returning canned web items. Assert (a) a run over one feed
  source (one item) and one web source (one item) stores two survivors under
  their classified kinds and `summary.sources == 2`; (b) a failing web source
  (stub returns an error) increments `failed_sources` by one and the run still
  stores the feed source's survivor; (c) a `pi` failure on a web survivor stores
  it under the fallback kind and is not a failed source; (d) `tryRun` returns
  `.busy` unchanged when the mutex is held (design D3, D4; spec: One curation
  run, Per-source error isolation, One run at a time).

## 4. Wire the run into the server (config + call sites)

- [ ] 4.1 In `src/server.zig`, pass `deps.cfg.web_sources`,
  `deps.cfg.lightpanda`, and `render_mod.acquireWeb` to both `tryRun` call sites
  — the `POST /curate` handler (`handleCurate`) and the daily scheduler loop.
  Import `render_mod = @import("render.zig")`. No change to the route contract,
  status codes, or auth ordering (design D1; spec: Curate endpoint, Daily
  scheduler).
- [ ] 4.2 Self-check (route handler): a `POST /curate` with a valid bearer and
  stubbed feed+web acquisition still returns `200 application/json` whose body
  parses with the summary keys; a busy run still returns `409`; a missing/wrong
  bearer still returns `401` before any acquisition (spec: Curate endpoint).

## 5. Integration

- [ ] 5.1 Register `src/render.zig` in `src/main.zig`'s comptime test import
  block so `zig build test` discovers it.
- [ ] 5.2 `zig build test` green; `openspec validate add-web-rendering` passes.
