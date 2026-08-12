## MODIFIED Requirements

### Requirement: JSON configuration loading

The system SHALL load its configuration from a JSON file parsed with
`std.json`. The default path SHALL be `$XDG_CONFIG_HOME/curation/config.json`
(resolving to `~/.config/curation/config.json` when `XDG_CONFIG_HOME` is
unset), overridable via a `--config <path>` flag and a `CURATION_CONFIG`
environment variable (flag takes precedence over env, env over default). The v1
schema SHALL recognize at minimum `host` (string), `port` (u16), `auth_token`
(string), `sources` (a list of feed source objects each carrying `name`
(string) and `url` (string)), and `schedule` (a string of the form `HH:MM`
denoting the daily local curation time, default `04:00`). When `sources` is
absent it SHALL be treated as an empty list; when `schedule` is absent it SHALL
be treated as `04:00`. Fields not in the schema SHALL be ignored so later
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

#### Scenario: absent sources defaults to an empty list

- **WHEN** the config file omits `sources`
- **THEN** the loaded configuration has zero feed sources

#### Scenario: sources are parsed with name and url

- **WHEN** the config file sets `sources` to
  `[{"name":"hackernews","url":"https://news.ycombinator.com/rss"}]`
- **THEN** the loaded configuration has one source whose `name` is `hackernews`
  and whose `url` is that feed URL

#### Scenario: absent schedule defaults to 04:00

- **WHEN** the config file omits `schedule`
- **THEN** the loaded configuration's daily curation time is `04:00`

## ADDED Requirements

### Requirement: Curate endpoint

The system SHALL expose `POST /curate` as a protected endpoint, gated by the
existing bearer-token authentication requirement (constant-time comparison of
the configured `auth_token`). Authentication SHALL precede all work: a request
without a valid bearer token SHALL respond `401` without starting a curation
run. For an authenticated request, the server SHALL attempt one curation run via
the `curation-job` capability's non-blocking probe: if the probe reports a run
was started and completed, the server SHALL respond `200 OK` with a
`Content-Type: application/json` body carrying the run summary, and SHALL NOT
attach an `X-Next-Token` header; if the probe reports a run was already in
progress, the server SHALL respond `409 Conflict` with an empty body and SHALL
start no run. The server SHALL be the sole trigger of the run via this endpoint
and SHALL NOT accept client-supplied run parameters beyond the configured state.
This endpoint SHALL be subject to the bearer-token authentication gate (it is a
protected endpoint).

#### Scenario: a valid bearer runs the job and returns the summary

- **WHEN** a client sends `POST /curate` with the configured bearer token and no
  run is in progress
- **THEN** the server starts one curation run, responds `200` with
  `Content-Type: application/json` and a body that is the run summary, and
  attaches no `X-Next-Token` header

#### Scenario: a run already in progress returns 409

- **WHEN** a client sends `POST /curate` with the configured bearer token while a
  curation run is already in progress
- **THEN** the server responds `409 Conflict` with an empty body and starts no
  new run

#### Scenario: a missing or wrong bearer returns 401 before running

- **WHEN** a client sends `POST /curate` with no `Authorization` header or a
  non-matching token
- **THEN** the server responds `401` without starting any curation run

### Requirement: Daily scheduler

The system SHALL run a daily curation run automatically by starting, when the
server starts serving, a background scheduler thread that aligns to the
configured `schedule` local time (default `04:00`) and, at that time, attempts
one curation run via the `curation-job` capability's non-blocking probe. If the
probe reports a run was already in progress, the scheduler SHALL log a structured
event and SHALL wait for the next scheduled time rather than queuing or
overlapping. The scheduler SHALL cooperate with graceful shutdown: it SHALL stop
promptly when the server is stopping (within a small bounded interval) and SHALL
not start a new run after shutdown has begun. The scheduler SHALL perform no HTTP
serving and SHALL obtain the run solely through the `curation-job` capability.

#### Scenario: the scheduler starts with the server

- **WHEN** the server begins serving
- **THEN** a scheduler thread is running that will attempt a curation run at the
  configured daily local time

#### Scenario: a busy probe is skipped and logged, not queued

- **WHEN** the scheduled time arrives and a curation run is already in progress
- **THEN** the scheduler logs an event, starts no new run, and waits for the next
  scheduled time

#### Scenario: the scheduler stops with the server

- **WHEN** the server receives a shutdown signal
- **THEN** the scheduler thread stops within a small bounded interval and does
  not start a curation run after shutdown has begun
