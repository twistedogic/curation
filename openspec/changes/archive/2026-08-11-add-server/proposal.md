## Why

`curation` is greenfield: only a stub `main.zig` exists (`.see/intent.md` §1).
Before the daily curation pipeline, the per-kind EPUB download, the embedded
UI, the Lightpanda renderer, or the `pi` longevity evaluator can be built,
there must be a running, observable, auth-protected HTTP server that loads its
configuration. That server is the bedrock every later change composes onto; it
is the smallest slice that is independently runnable and verifiable, so it is
the right thing to land first (US-001, US-005, and the skeleton of US-006).

## What Changes

- Add `curation serve` — an HTTP server (`std.http.Server`) listening on a
  configurable host/port, with graceful shutdown on interrupt.
- Load configuration from JSON (`std.json`) at the XDG config path
  (`$XDG_CONFIG_HOME/curation/config.json`, override via `--config` / env). The
  v1 schema carries only the fields the server needs now: `host`, `port`,
  `auth_token`; unknown/extra fields are ignored so later changes extend it.
- Add `GET /healthz` → `200` readiness probe (no auth).
- Add a single shared bearer token gate (constant-time compare) so write
  endpoints introduced later are protected from day one. In this change it gates
  nothing yet except itself; `GET /` and `GET /healthz` stay open.
- Add structured key/value logging (INFO/WARN/ERROR, stable fields) on startup
  and request paths, and a `GET /metrics` Prometheus exposition endpoint with a
  minimal starting set (request count + latency histogram, uptime gauge).
- Everything runs through `zig build` / `zig build test`; no in-binary
  dependency is added (stdlib-only, per intent §2).

## Capabilities

### New Capabilities
- `server`: The curation HTTP server's lifecycle and cross-cutting
  infrastructure — startup/shutdown, JSON configuration loading from the XDG
  path, the readiness endpoint, the shared bearer-token auth gate, structured
  logging, and the Prometheus metrics exposition endpoint. This is the
  foundation that the curation pipeline, EPUB download, and embedded UI attach
  to in later changes.

### Modified Capabilities
<!-- None — greenfield; no specs exist yet. -->

## Impact

- **Code:** new `src/` modules for server lifecycle, config, logging, metrics,
  and auth; `main.zig` gains `serve` and wires `--config`. No existing behavior
  changes (the stub `main.zig` is replaced).
- **Config:** introduces the JSON config file and its first fields
  (`host`, `port`, `auth_token`); later changes extend the same file.
- **Dependencies:** none added — Zig 0.16 stdlib only.
- **Automation:** `Taskfile.yml` already provides `build`/`test`/`run`; `task
  run -- serve` exercises the new command. No CI changes beyond what Task
  already drives.
