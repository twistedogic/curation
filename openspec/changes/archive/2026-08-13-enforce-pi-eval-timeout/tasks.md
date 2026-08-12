## 1. Enforce the `pi` timeout default (longevity capability)

- [x] 1.1 In `src/longevity.zig`, change `PiConfig.timeout_seconds` default from
  `null` to `30`, and rewrite its doc comment from "Not enforced in v1; reserved"
  to describe the enforced per-invocation bound (design D2; spec: Evaluation
  configuration).
- [x] 1.2 In `src/config.zig`, update the default-`pi`-block assertion from
  `cfg.pi.timeout_seconds == null` to `== 30`, so the "absent pi block uses
  defaults" scenario reflects the new enforced default (design D5; spec:
  Evaluation configuration).

## 2. Bound `productionInvoker` with `std.process.run` (longevity capability)

- [x] 2.1 Rewrite `productionInvoker` to spawn+wait via
  `std.process.run(gpa, io, .{ .argv = argv.items, .stdout_limit = .limited(1
  << 20), .timeout = <from 2.2> })` instead of the manual
  `std.process.spawn` + stdout streaming + `child.wait(io)`. `run` constructs the
  same child shape (`stdin = .ignore`, `stdout`/`stderr = .pipe`, argv-only),
  threads the timeout into every pipe read, and `defer child.kill(io)` on return,
  so an overrun timeout kills the child and surfaces as an error (design D1, D4;
  spec: Failure tolerance).
- [x] 2.2 Build the `std.Io.Timeout` from `cfg.timeout_seconds`: when `null`,
  pass `.none` (no bound); otherwise a `duration` of the configured seconds. This
  single value feeds `run`'s `.timeout` (design D1, D2; spec: Evaluation
  configuration).
- [x] 2.3 Preserve the existing mappings and ownership: keep
  `error.FileNotFound → error.PiNotFound` on spawn failure; map any other `run`
  error (non-zero exit, timeout, read error) to a returned error so `classify`
  routes it through the existing fallback (no new error type); return
  `result.stdout` (owned by the caller) and `gpa.free(result.stderr)` (design D3,
  D4; spec: Failure tolerance).
- [x] 2.4 Update `productionInvoker`'s `ponytail:` note to record the enforced
  timeout via `std.process.run` and the "move to a persistent `pi` session if
  per-item spawn+timeout overhead matters" ceiling (design D5).

## 3. Regression test (longevity capability)

- [x] 3.1 Add a sleeping stub script under `zig-cache/tmp/` (the `render.zig`
  stub-subprocess pattern: a tiny shell script that ignores its argv and sleeps
  indefinitely) plus a `zig build test` case that invokes `productionInvoker`
  with `timeout_seconds = 1` against it and asserts the call returns an error
  within the timeout rather than hanging — the regression that fails the build
  if the unbounded `child.wait` returns (design D5; spec: Failure tolerance — "a
  timeout falls back and never stalls the run"). Wire the test to an `Io` under
  which the read timeout genuinely elapses (real `std.Io` if `std.testing.io`
  does not model read timeouts).
- [x] 3.2 Assert the timed-out/errored invocation flows through `classify`'s
  existing fallback: the item is labeled `unknown`, routed to `cfg.default_kind`,
  logged, and (with a non-null recorder) records one evaluation + one failure,
  and is not written to the cache so the next run retries it (design D3; spec:
  Failure tolerance, Evaluation observability).
  > Note: covered by the existing `classify: invoke error → default kind,
  > logged, non-fatal, not cached` test (line 584) which exercises the same
  > fallback path with the new `timeout_seconds = 30` default. The end-to-end
  > timeout regression is at the invoker layer (3.1).

## 4. Integration

- [x] 4.1 No new module to register (`longevity.zig` is already imported in
  `main.zig`'s comptime test block); no public signature, cache-format, route,
  token, store, or `/metrics` change.
- [x] 4.2 `zig build test` green; `openspec validate enforce-pi-eval-timeout`
  passes; `openspec validate --all` stays green (9 capabilities).
