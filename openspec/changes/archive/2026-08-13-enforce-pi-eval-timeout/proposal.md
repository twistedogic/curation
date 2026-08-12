## Why

Intent **US-009** / **FR-15** require that a `pi` invocation that *"fails / times
out / is unparseable"* is treated as the label `unknown`, which routes to the
configured-default kind and *"never aborts the run,"* and §8 names as a success
metric that *"a `pi` failure never blocks a run."* The `longevity` spec already
encodes this: the **Failure tolerance** requirement lists *"a timeout"* as a
handled failure mode, **Evaluation configuration** declares a `timeout_seconds`
field, and the observability scenario says the invoker errors when the binary
*"cannot start, exits non-zero, or times out."*

The code does not honour any of it. `productionInvoker`
(`src/longevity.zig`) spawns `pi` with `std.process.spawn` and then calls
`child.wait(io)`, which has **no timeout argument** — a `pi` process that hangs
(a slow model, a wedged provider connection) blocks the calling thread forever.
Meanwhile the `PiConfig.timeout_seconds` field exists, is parsed from config,
and is even unit-tested — but its own doc comment admits *"Not enforced in v1;
reserved."* So today a single hung classification stalls the daily curation run
indefinitely, directly violating the spec's "a timeout" clause and the intent's
"never blocks a run" guarantee. This is the one remaining failure mode the
longevity path claims to handle but does not.

## What Changes

- **Enforce the `pi` call timeout.** Replace `productionInvoker`'s manual
  `std.process.spawn` + `child.stdout` streaming + `child.wait(io)` sequence
  with `std.process.run(gpa, io, .{ …, .timeout = <from cfg.timeout_seconds> })`.
  `run` already builds the exact child shape this function wants (`stdin =
  .ignore`, `stdout`/`stderr` piped, argv-only), passes the timeout to every
  read, and — critically — carries `defer child.kill(io)`, so a `pi` that
  overruns the timeout is killed and `run` returns an error rather than
  hanging. This is the same `std.process.run` + `.timeout` pattern the sibling
  `sources` capability already uses to bound the Lightpanda subprocess
  (`render.zig`); no new mechanism.
- **Make the timeout on by default.** Change `PiConfig.timeout_seconds` from a
  default of `null` (unbounded) to a sensible enforced default (`30`), so the
  spec's "a timeout" guarantee holds out of the box. Operators may still raise,
  lower, or disable it (`null`) per deployment. Update the field's doc comment
  from *"Not enforced in v1; reserved"* to describe the enforced behaviour.
- **Map the timeout to the existing fallback.** `productionInvoker` already
  returns an error on a non-zero exit; `run`'s timeout surfaces as an error in
  the same path, and `classify` already turns any invoker error into the
  recorded failure + `cfg.default_kind` return (no caller change). No new error
  type is required to satisfy the contract.
- **Add a regression test.** A stub script (the `render.zig` stub-subprocess
  pattern, already proven in this repo) that ignores its argv and sleeps
  forever, invoked via `productionInvoker` with `timeout_seconds = 1`, asserts
  the call returns an error within the timeout instead of hanging — so the
  unbounded-`wait` regression fails the build if it returns. Update the
  `config.zig` default-`pi`-block test to the new enforced default.
- Standard library only; `zig build test` stays green. Single binary, no new
  dependency, no store/config-format/route/token change.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `longevity`: the **Failure tolerance** requirement gains an explicit "a
  timeout falls back" scenario asserting a `pi` invocation that does not
  terminate within the configured `timeout_seconds` is bounded, killed, and
  labeled `unknown` → configured-default kind, logged, non-fatal (the prose
  already lists "a timeout"; this makes it testable). The **Evaluation
  configuration** requirement is clarified so `timeout_seconds` is enforced
  with a documented default (it is no longer merely "reserved"), and the
  "absent pi block uses defaults" scenario reflects the enforced default. The
  label-to-kind mapping, strict label parsing, the evaluation cache, the
  evaluation-observability contract, and the capability boundary are unchanged.

## Impact

- **Code:** `src/longevity.zig` — `productionInvoker` is rewritten to use
  `std.process.run` (preserving the 1 MiB stdout cap via `.stdout_limit` and the
  `FileNotFound → PiNotFound` mapping); its `ponytail:` note is updated. The
  `PiConfig.timeout_seconds` default changes `null → 30` and its doc comment is
  rewritten. No other `.zig` file changes.
- **Config test:** `src/config.zig` — the default-`pi`-block assertion
  (`cfg.pi.timeout_seconds == null`) becomes `== 30`; the custom-config test
  (`timeout_seconds: 30`) is unchanged.
- **APIs:** none. `productionInvoker` is an internal invoker (opt-in manual
  test today); the public `classify`/`Invoker` surface, the `Kind`/`Label`
  enums, the eval-cache file format, and the `/metrics` exposition are
  unchanged. A hung `pi` now resolves to the default kind after the timeout
  instead of stalling — strictly the behaviour US-009 already requires.
- **Dependencies:** none added — Zig 0.16 standard library only. Single binary;
  no external runtime dependency.
- **Data:** no store, cache-file, token, or record-format change. A timed-out
  classification is `unknown`, which (per existing behaviour) is **not** written
  to the eval cache, so the next run retries it — unchanged.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the new
  timeout regression (stub sleeps, `productionInvoker` returns an error within
  the configured timeout instead of hanging) and the updated default.
