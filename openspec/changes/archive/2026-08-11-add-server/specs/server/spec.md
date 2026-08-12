## ADDED Requirements

### Requirement: Server lifecycle

The system SHALL provide a `curation serve` command that starts an HTTP server
using `std.http.Server`, binds to the configured host and port, and serves
requests. The server SHALL shut down gracefully on an interrupt signal
(SIGINT), stopping new connections without aborting a response mid-write.

#### Scenario: serve listens on configured address

- **WHEN** the operator runs `curation serve` with a config specifying
  `host=127.0.0.1` and `port=8787`
- **THEN** the server binds to `127.0.0.1:8787` and accepts HTTP requests there

#### Scenario: graceful shutdown on interrupt

- **WHEN** the server receives SIGINT while running
- **THEN** it stops accepting new connections, completes any in-flight response,
  and exits with status 0

#### Scenario: missing serve command shows usage

- **WHEN** the operator runs `curation` with no subcommand
- **THEN** it exits non-zero with a usage message naming `serve`

### Requirement: JSON configuration loading

The system SHALL load its configuration from a JSON file parsed with
`std.json`. The default path SHALL be `$XDG_CONFIG_HOME/curation/config.json`
(resolving to `~/.config/curation/config.json` when `XDG_CONFIG_HOME` is
unset), overridable via a `--config <path>` flag and a `CURATION_CONFIG`
environment variable (flag takes precedence over env, env over default). The
v1 schema SHALL recognize at minimum `host` (string), `port` (u16), and
`auth_token` (string). Fields not in the schema SHALL be ignored so later
changes extend the file without breaking this loader.

#### Scenario: default config path resolves via XDG

- **WHEN** `XDG_CONFIG_HOME=/tmp/xdg` and no flag/env is set
- **THEN** the loader reads `/tmp/xdg/curation/config.json`

#### Scenario: flag overrides environment

- **WHEN** `--config /etc/c.json` is given and `CURATION_CONFIG=/other` is set
- **THEN** the loader reads `/etc/c.json`

#### Scenario: unknown fields are ignored

- **WHEN** the config file contains `{"host":"0.0.0.0","port":1,"future_field":42}`
- **THEN** parsing succeeds and `future_field` does not cause an error

#### Scenario: missing config file fails loudly

- **WHEN** the resolved config path does not exist
- **THEN** startup logs an ERROR with the path and exits non-zero before
  binding any port

### Requirement: Health and readiness endpoint

The system SHALL expose `GET /healthz`, which returns HTTP `200` with an empty
body when the server is up. This endpoint SHALL NOT require authentication.

#### Scenario: healthz returns 200 unauthenticated

- **WHEN** a client sends `GET /healthz` with no credentials
- **THEN** the server responds `200` with an empty body

### Requirement: Bearer token authentication gate

The system SHALL authenticate protected endpoints using a single shared bearer
token from the config (`auth_token`), validated by constant-time comparison of
the raw token bytes. A request to a protected endpoint SHALL be accepted only
when its `Authorization: Bearer <token>` header matches the configured token.
`GET /` and `GET /healthz` SHALL be open (not subject to this gate). In this
change the gate exists and is exercised by tests; later changes attach the
download and write endpoints to it.

#### Scenario: protected endpoint accepts valid token

- **WHEN** a request to a protected endpoint carries the configured bearer token
- **THEN** the request proceeds normally

#### Scenario: protected endpoint rejects missing or wrong token

- **WHEN** a request to a protected endpoint carries no `Authorization` header
  or a non-matching token
- **THEN** the server responds `401` without performing the protected action

#### Scenario: open endpoints ignore credentials

- **WHEN** a client requests `GET /healthz` or `GET /` with no credentials
- **THEN** the request is served (not 401)

### Requirement: Structured logging

The system SHALL emit structured key/value log lines at INFO, WARN, and ERROR
levels on a single output stream. On startup it SHALL log at INFO the listen
address and a stable set of fields (e.g. `level`, `event`, `addr`). Per-request
logging SHALL include method, path, and status as stable fields. Log field
names SHALL be stable across releases once introduced.

#### Scenario: startup emits listen address

- **WHEN** the server starts successfully bound to `127.0.0.1:8787`
- **THEN** it emits an INFO log line whose fields include the event and the
  address `127.0.0.1:8787`

#### Scenario: request is logged

- **WHEN** a `GET /healthz` request is served with status 200
- **THEN** a log line is emitted including method `GET`, path `/healthz`, and
  status `200`

### Requirement: Prometheus metrics endpoint

The system SHALL expose `GET /metrics` returning a Prometheus text exposition
(`Content-Type: text/plain; version=0.0.4`). The initial metric set SHALL
include an HTTP request counter and an HTTP request latency histogram keyed by
method and path, plus a process uptime gauge. This endpoint SHALL NOT require
authentication so a scraper can poll it.

#### Scenario: metrics are exposed in Prometheus text format

- **WHEN** a client sends `GET /metrics`
- **THEN** the response has Content-Type
  `text/plain; version=0.0.4` and a body containing at least the request
  counter, the latency histogram, and the uptime gauge

#### Scenario: requests increment the counter

- **WHEN** two `GET /healthz` requests are served, then `GET /metrics` is read
- **THEN** the request counter reflects at least those two healthz requests for
  `method=GET,path=/healthz`

#### Scenario: metrics endpoint is open

- **WHEN** a client sends `GET /metrics` with no credentials
- **THEN** the server responds `200` with the exposition body (not 401)
