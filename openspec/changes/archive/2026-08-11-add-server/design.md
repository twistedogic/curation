## Context

`curation` is greenfield: only a stub `main.zig` (`task run` prints `curation`)
and a `build.zig` exist. `.see/intent.md` fixes the stack (Zig 0.16.0,
stdlib-only single binary) and the server as the bedrock that the pipeline,
EPUB download, embedded UI, Lightpanda renderer, and `pi` longevity evaluator
all attach to (US-001, US-005, US-006). This change lands that bedrock — a
running, configurable, observable, auth-ready HTTP server — and nothing more.
It is deliberately the smallest independently runnable and testable slice.

## Goals / Non-Goals

**Goals:**
- A `curation serve` HTTP server (`std.http.Server`) on a configurable
  host/port with graceful interrupt shutdown.
- JSON config (`std.json`) from the XDG path with `--config` / `CURATION_CONFIG`
  overrides; first fields `host`, `port`, `auth_token`; tolerant of unknown
  fields.
- `GET /healthz` (200, open) and `GET /metrics` (Prometheus exposition, open).
- A constant-time bearer-token auth gate, open endpoints bypass it.
- Structured key/value logging on startup and per-request.

**Non-Goals:**
- The curation pipeline (US-002/003), per-kind EPUB download (US-004), the
  embedded UI (US-007), Lightpanda rendering (US-008), and the `pi` longevity
  evaluator (US-009) — each is its own later change.
- The download/write endpoints themselves: the auth gate is built now, the
  endpoints that use it are not.
- TOML or any config format other than JSON; no config-file generation/wizard.
- TLS termination (behind a reverse proxy in v1).

## Decisions

### D1. Single-threaded accept loop with per-connection handlers
The v1 server runs one blocking accept loop on `std.http.Server`, handling one
connection at a time. Curation is single-user, low-frequency (a daily curate
job plus a handful of EPUB downloads); throughput is not a concern at this
scale.
- *Alternative:* a thread-per-connection or async runtime. Rejected — adds
  complexity and shared-state hazards for load this project will never see.
- `// ponytail: single accept loop, single-user/daily-cadence; add
  concurrency only if a measured latency target demands it.`

### D2. Config as a parsed struct with tolerant unknown fields
Define a `Config` struct (`host`, `port`, `auth_token`) and decode the JSON
into it with `std.json`. `std.json.Value`/`parseFromSlice` into a struct
ignores fields absent from the struct by default, giving forward compatibility
for free. Resolution order flag → env → XDG default is one small function.
- *Alternative:* a generic map. Rejected — loses type safety and the "boring"
  principle; a struct is clearer at 3am.

### D3. Auth as a small gate, not a framework
A function `checkBearer(header_value, configured_token) bool` using
`std.crypto.utils.timingSafeEql` (constant-time compare on equal-length slices,
length-checked first). A route table marks each route open/protected; open
routes skip the check. No middleware abstraction, no roles — one token, one
gate.
- `// ponytail: single shared token, single client; revisit if multi-client
  per-item tokens ever appear.`

### D4. Logging as structured key/value lines, written directly
Emit `level=info event=server.start addr=127.0.0.1:8787 …` style lines to a
single stream (stderr), built with a small `std.ArrayList(u8)` + `std.fmt`.
No logging library; the field set is tiny and stable. This satisfies the
observability principle (AGENTS.md) without a dependency.
- *Alternative:* a vendored logger. Rejected — stdlib `fmt` covers it.

### D5. Metrics hand-rolled in Prometheus text exposition
The Prometheus text format is trivial: `# HELP`, `# TYPE`, then
`name{labels} value` lines. A `Metrics` struct holds counters (u64) and a
latency histogram (fixed buckets) and renders itself on `GET /metrics`. No
client library.
- *Alternative:* a vendored prometheus client. Rejected — the format is ~30
  lines and a dependency is unjustified for three metrics.
- `// ponytail: fixed histogram buckets; tune buckets when real latency
  distribution is known.`

### D6. Graceful shutdown via SIGINT
Install a SIGINT handler that flips an `AtomicValue(bool)` stop flag the accept
loop checks between connections; in-flight responses complete naturally. No
half-written response bodies (a response is written in one go before the loop
checks the flag).
- `// ponytail: cooperative shutdown between connections; hard-cancel a
  long-running in-flight request only if one ever appears (the curation job
  lands in a later change and will need its own stop wiring).`

## Risks / Trade-offs

- **[SIGINT handling differs across targets]** → Mitigation: use stdlib signal
  facilities; gate the test to where stdlib supports it; the flag check is the
  contract, the signal wiring is thin.
- **[Single-threaded accept blocks on a slow client]** → Mitigation: per-route
  read/response is bounded by HTTP semantics; acceptable at this load. Ceiling
  noted in D1.
- **[Prometheus histogram bucket choice]** → Mitigation: pick conservative
  default buckets; D5 ceiling names the tuning trigger.
- **[Auth built before any protected endpoint exists]** → Mitigation: the gate
  is unit-tested with the constant-time comparator and exercised through the
  open-endpoint bypass; US-005 acceptance (401 on bad token) is met by the
  mechanism. Avoids rework when US-004 attaches `/download`.

## Migration Plan

Greenfield — no migration. Deploy by: add a `config.json` at the XDG path with
`host`/`port`/`auth_token`, then `task build && task run -- serve`. Rollback is
`git revert`; nothing persists yet (no store is introduced in this change).

## Open Questions

- None blocking. The XDG resolution and the exact metric/label names are fixed
  in the spec; they can be refined in review without re-scoping.
