## 1. Project scaffolding

- [x] 1.1 Create `src/` module layout: `main.zig` (CLI dispatch), `config.zig`,
  `server.zig`, `auth.zig`, `log.zig`, `metrics.zig`.
- [x] 1.2 Confirm `zig build` and `zig build test` pass after the empty modules
  are added (no behavior yet).

## 2. Configuration loading

- [x] 2.1 Implement `Config` struct (`host`, `port`, `auth_token`) decoded via
  `std.json`, tolerant of unknown fields (design D2).
- [x] 2.2 Implement path resolution: `--config` flag → `CURATION_CONFIG` env →
  `$XDG_CONFIG_HOME/curation/config.json` (default `~/.config/...`).
- [x] 2.3 Add a self-check: flag overrides env; unknown fields ignored; missing
  file fails with a path-bearing error (spec: JSON configuration loading).

## 3. Structured logging

- [x] 3.1 Implement key/value line writer (INFO/WARN/ERROR) to stderr with
  stable field names (design D4).
- [x] 3.2 Add a self-check: a startup line carries `event` and `addr` fields.

## 4. Bearer auth gate

- [x] 4.1 Implement `checkBearer(header_value, configured_token)` with
  constant-time compare (length-checked first, design D3).
- [x] 4.2 Add a self-check: valid token accepted; missing/mismatched rejected;
  open routes bypass (spec: Bearer token authentication gate).

## 5. Metrics

- [x] 5.1 Implement `Metrics` with an HTTP request counter, a latency histogram
  (fixed buckets), and an uptime gauge, rendering Prometheus text exposition
  (design D5).
- [x] 5.2 Add a self-check: exposition body contains the three metric families
  and the correct Content-Type.

## 6. HTTP server

- [x] 6.1 Implement `curation serve` accept loop on `std.http.Server` bound to
  `host`/`port`, checking a stop flag between connections (design D1, D6).
- [x] 6.2 Route `GET /healthz` → 200 (open) and `GET /metrics` → exposition
  (open); route table marks each route open/protected.
- [x] 6.3 Wire SIGINT to flip the stop flag and close the listening socket for
  graceful shutdown. (close-from-signal-handler unblocks accept on macOS;
  `shutdown()` does not — noted in code.)
- [x] 6.4 Add a self-check (in-process): healthz returns 200 open; metrics
  increments the counter for the served path; open routes ignore credentials
  (spec: server lifecycle, health/readiness, metrics endpoint).

## 7. CLI dispatch and integration

- [x] 7.1 `main.zig` parses the subcommand; `serve` wires config + server; no
  subcommand prints usage and exits non-zero.
- [x] 7.2 End-to-end manual check: write a minimal `config.json`, run
  `task run -- serve --config …`, hit `/healthz` and `/metrics`, confirm
  startup logs include the listen address and shutdown is graceful on SIGINT.
- [x] 7.3 `zig build test` green.
