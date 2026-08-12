## Context

`curation`'s longevity path is built: the `longevity` capability classifies each
curated item `short_term`/`long_term` by invoking the local `pi` agent CLI,
caches results on SHA-256(title+body), and is failure-tolerant — any error
falls back to the configured-default kind so a model hiccup never aborts the
daily run (US-009 / FR-15). `classify`
(`src/longevity.zig`) already turns **any** error from its `Invoker` into a
recorded failure plus a `cfg.default_kind` return; the fallback machinery is
complete.

The one failure mode the spec names that the code does **not** honour is
**timeout**. The spec is explicit in three places:

- **Failure tolerance** — *"a non-zero exit, **a timeout**, or an unparseable
  result … as the label `unknown`."*
- **Evaluation configuration** — declares a `timeout_seconds` field.
- **Evaluation observability** — the invoker errors when the binary *"cannot
  start, exits non-zero, **or times out**."*

But `productionInvoker` spawns `pi` with `std.process.spawn` and then
`child.wait(io)`, and Zig 0.16's `Child.wait` takes **no timeout** — it blocks
until the child exits. Meanwhile `PiConfig.timeout_seconds` is parsed and even
unit-tested, yet its doc comment says *"Not enforced in v1; reserved."* So a
single `pi` process that hangs (a slow provider, a wedged connection) stalls the
calling thread indefinitely, violating the spec's "a timeout" clause and the
intent's "a `pi` failure never blocks a run" success metric. The sibling
`sources` capability already solved the identical problem for the Lightpanda
subprocess (`render.zig`): it bounds the child with `std.process.run(…,
.{ .timeout = … })`. This change applies that same, proven pattern to `pi`.

## Goals / Non-Goals

**Goals:**
- A `productionInvoker` whose wall-clock time is bounded by the configured
  `timeout_seconds`: a `pi` that does not terminate in time is killed and
  reported as an error, which `classify` already maps to `unknown` →
  configured-default kind — so a wedged classification never stalls the run.
- `timeout_seconds` enforced **by default** (a documented default, overridable
  to `null`), so the spec's guarantee holds out of the box.
- `openspec validate enforce-pi-eval-timeout` passes; `openspec validate --all`
  stays green; `zig build test` stays green.

**Non-Goals:**
- No change to the public `classify` / `Invoker` surface, the `Kind`/`Label`
  enums, the eval-cache format, or `/metrics` exposition. The fallback, the
  cache, and the observability contract are already correct; this change only
  makes `productionInvoker` actually return an error on timeout.
- No retries, backoff, or concurrency for `pi` evaluations (one invocation per
  uncached item, as today). The daily cap (US-003) bounds total evaluator cost.
- No new error type surfaced to callers. `run`'s timeout/error flows through the
  existing `anyerror` invoker path to the existing fallback.
- No change to the prompt, the `--no-tools`/`--no-context-files`/`--no-session`
  flags, the `--model` pin, the cache key, or any other capability. Standard
  library only; single binary; no new dependency.

## Decisions

### D1 — Bound `pi` with `std.process.run(…, .{ .timeout })`, not a manual spawn+wait+timer

`productionInvoker`'s current shape — `spawn` with `stdin = .ignore`,
`stdout`/`stderr = .pipe`, then stream stdout, then `child.wait(io)` — is
exactly the child shape `std.process.run` constructs internally
(`stdin = .ignore`, `stdout`/`stderr = .pipe`, argv-only). `run` differs in two
load-bearing ways: it threads `options.timeout` into every pipe read
(`multi_reader.fill(…, options.timeout)`), and it carries
`defer child.kill(io)`, so when a read times out `run` returns the error *and*
kills the child. Re-implementing that (a manual `spawn`, a timer thread, a
`child.kill` race) would be strictly more code to reproduce what `run` already
does. This is also the function the sibling `sources` capability uses to bound
Lightpanda, so it is the in-repo convention. Lazy fix = reuse `run`.

### D2 — Enforce by default (`timeout_seconds` default `null → 30`), overridable

The spec *requires* the timeout to be handled, so a `null` (unbounded) default
leaves the requirement unsatisfied for every deployment that does not
hand-configure the field — i.e. the bug persists by default. A 30-second default
delivers the guarantee out of the box while staying generous (a single model
classification rarely exceeds it; the daily cap bounds total cost). `null`
remains a valid override for operators who want no bound. The default lives in
`PiConfig`, so the "absent `pi` block uses defaults" config scenario simply
reflects the new default.

### D3 — Flow `run`'s error through the existing fallback; no new error type

`classify` maps any `Invoker` error to a recorded failure + `cfg.default_kind`
return; `productionInvoker` already returns an error on a non-zero exit.
`run`'s timeout surfaces as an error on that same path, so `classify` needs no
change. Keeping the `FileNotFound → error.PiNotFound` mapping preserves the
existing "missing binary" behaviour and log message. No new variant is added to
any public error set.

### D4 — Preserve the existing bounds and mappings

`productionInvoker` today caps stdout at 1 MiB (`allocRemaining(…,
.limited(1 << 20))`). `std.process.run` defaults `stdout_limit` to
`.unlimited`, so the rewrite sets `.stdout_limit = .limited(1 << 20)` (and frees
`result.stderr`, which `run` captures but this invoker does not return) to keep
the memory ceiling and the ownership contract identical to today.

### D5 — Regression test via the stub-subprocess pattern `render.zig` already uses

`render.zig` proves the repo can test a real child process hermetically: it
writes a tiny shell stub to `zig-cache/tmp/`, marks it executable, and drives
the acquisition function through it. The same pattern produces a stub that
ignores its argv and sleeps forever; invoking it through `productionInvoker`
with `timeout_seconds = 1` asserts the call returns an error within the timeout
instead of hanging — the exact regression (unbounded `child.wait`) that fails
the build if it returns. The config default (`null → 30`) is covered by updating
the existing default-`pi`-block assertion in `config.zig`.

`// ponytail: timeout enforced via std.process.run's per-read timeout + defer
// child.kill; one bound per invocation. Move to a pi --model batch / persistent
// session if per-item spawn+timeout overhead matters at high item counts.`

## Risks / Trade-offs

- **A genuinely-slow but successful classification near the bound may be killed.**
  → Mitigation: 30 s is generous for a single short/long classification, the
  default is operator-tunable, and a killed call is non-fatal (falls back to the
  default kind and is *not* cached, so the next run retries it). The cost of a
  mis-kill is one re-evaluation; the cost of the status quo is an indefinite
  run stall.
- **`std.process.run`'s timeout is applied per pipe-read, not as a hard total
  deadline.** For a process that produces output then hangs, the bound applies
  to the gap after the last output; for the failure mode that matters here (a
  `pi` that produces nothing and never exits), the first read times out, so the
  effect is a total bound. → Mitigation: the regression test exercises exactly
  the "produces nothing, never exits" shape, which is the stall the spec forbids.
- **Test-io time model.** `render.zig` runs real subprocesses under
  `std.testing.io`, so spawning works in the test harness; whether
  `std.testing.io` honours a read timeout is less certain. → Mitigation: the
  timeout regression drives a *real* sleeping stub so a genuine timeout must
  elapse; if `std.testing.io` does not model the read timeout, the test is wired
  to the real `std.Io` (the same one production uses) so the bound genuinely
  fires. The apply step resolves the exact `Io`; the design commits to "a real
  sleeping stub + the configured timeout returns an error, never hangs."
- **Default change is observable.** Deployments that relied on the implicit
  unbounded default now get a 30 s bound. → Mitigation: this is the spec-required
  behaviour, `null` restores the old bound, and no successful in-spec
  classification is affected (30 s is well above normal latency). Noted in the
  proposal's Impact under Config.
