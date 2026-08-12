## Why

`curation` can fetch feeds, parse them, and run the deterministic
normalize/dedupe/filter/tag/cap pipeline (archived `add-server`,
`add-curation-pipeline`, `add-feed-fetching`). But that pipeline deliberately
ends at the cap — it does not yet decide which items are disposable news and
which are durable knowledge. Per intent FR-5 the next stage is longevity
evaluation: each surviving item is labeled **short_term** or **long_term**
through `pi`, and that label is what splits the output into the two streams
(news / knowledge) that everything downstream — storage routing, the two
per-kind EPUBs, the per-kind watermarks — depends on. This is the smallest
slice that produces a stream kind, and it is the only non-deterministic step
in an otherwise deterministic pipeline, so it is kept isolated, cached, and
failure-tolerant.

## What Changes

- Add a **longevity evaluator** that, for a given curated item (title + body),
  renders the configured classification prompt, invokes `pi` out-of-process
  (`pi -p "<prompt>" --no-tools --no-context-files --no-session`, optionally
  `--model <cheap/fast>`), and parses exactly one token — `short_term` or
  `long_term` — from stdout. The label maps to a **kind**: `short_term` →
  `news`, `long_term` → `knowledge`.
- Make evaluation **failure-tolerant**: any failure — `pi` missing, non-zero
  exit, timeout, or an unparseable result — assigns the label `unknown`, which
  falls back to a configured default kind (default `news`), is logged, and
  never aborts. A bad label can misfile one item; it never breaks a run.
- Add a **SHA-256(title+body)-keyed evaluation cache** persisted under the XDG
  cache dir so a re-run (manual `POST /curate`, retry, restart) does not
  re-spend on content already classified.
- Add **eval configuration** as a nested `pi` block in the same JSON config:
  the binary path, an optional `--model` pin, the classification prompt, the
  failure-fallback default kind, and an optional timeout. curation holds **no**
  provider/model/API-key — `pi` owns all credentials and routing.
- Keep the **subprocess spawn behind an injectable seam** so the
  parse → cache → fallback logic is a pure, unit-tested core that needs no
  real `pi`; the seam is the only I/O boundary.
- stdlib-only (`std.process.Child`, `std.crypto.hash.sha2`, `std.json`,
  `std.fs`, `std.testing`); no new dependency. Not wired into any request path
  in this change; `zig build test` stays green.

## Capabilities

### New Capabilities
- `longevity`: The pi-based longevity evaluator — the only non-deterministic
  stage of the pipeline. Given a curated item's title + body, it produces a
  stream kind (`news`/`knowledge`) by wrapping `pi`, caching results on
  SHA-256(title+body), and degrading to a configured-default kind on any
  failure. Owns the eval seam and the eval config; owns no scheduling, storage,
  or endpoint.

### Modified Capabilities
<!-- None. Config loading behavior (server capability) is unchanged: the loader
already ignores unknown fields, so adding a recognized `pi` block needs no
spec-level change to `server`. The `curation` pipeline still ends at cap; it
hands curated items to this evaluator unchanged. -->

## Impact

- **Code:** new `src/longevity.zig` (label/kind types, evaluator, cache,
  injectable pi-invoker seam) and a small `pi`-block extension to
  `src/config.zig` (decoded by the existing `std.json` loader). No existing
  behavior changes; the server still serves the placeholder `/`.
- **Config:** introduces an optional nested `pi` object in `config.json`
  (`path`, `model`, `prompt`, `default_kind`, `timeout_seconds`); all fields
  take documented defaults, so omitting the block keeps curation buildable but
  leaves evaluation at defaults until an operator tunes it.
- **Dependencies:** none added — Zig 0.16 stdlib only. `pi` is an external,
  configured runtime tool, never vendored into the binary.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the new
  self-checks (a stubbed invoker for the pure logic; the real subprocess path
  is exercised only by an opt-in manual check, not the default test suite).
