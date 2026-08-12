# server Specification

## Purpose
The HTTP surface: lifecycle, configuration, the `/healthz`, `/`, and `/metrics`
open endpoints, the bearer-token authentication gate, structured logging, and
the protected `GET /download` endpoint that streams per-kind EPUBs (or `204`)
via the `download` capability. Pure route handlers live here; the download
engine itself is the `download` capability.
## Requirements
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
environment variable (flag takes precedence over env, env over default). The v1
schema SHALL recognize at minimum `host` (string), `port` (u16), `auth_token`
(string), `sources` (a list of feed source objects each carrying `name`
(string) and `url` (string)), `web_sources` (a list of web-content source
objects each carrying `name` (string) and `url` (string)), `lightpanda` (an
object carrying `path` (string, default `lightpanda`) and `dump_format` (one of
`markdown` or `html`, default `markdown`)), `schedule` (a string of the form
`HH:MM` denoting the daily local curation time, default `04:00`), and
`retention_days` (a non-negative integer, default `90`, where `0` disables
age-based pruning). When `sources` or `web_sources` is absent it SHALL be
treated as an empty list; when `schedule` is absent it SHALL be treated as
`04:00`; when the `lightpanda` object is absent its fields SHALL take their
documented defaults; when `retention_days` is absent it SHALL be `90`. Fields
not in the schema SHALL be ignored so later changes extend the file without
breaking this loader.

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
- **THEN** the loaded configuration has one feed source whose `name` is
  `hackernews` and whose `url` is that feed URL

#### Scenario: absent web_sources defaults to an empty list

- **WHEN** the config file omits `web_sources`
- **THEN** the loaded configuration has zero web-content sources

#### Scenario: web sources are parsed with name and url

- **WHEN** the config file sets `web_sources` to
  `[{"name":"cnn","url":"https://www.cnn.com"}]`
- **THEN** the loaded configuration has one web-content source whose `name` is
  `cnn` and whose `url` is `https://www.cnn.com`

#### Scenario: an absent lightpanda block uses defaults

- **WHEN** the config file omits the `lightpanda` object
- **THEN** the loaded configuration's `lightpanda.path` is `lightpanda` and its
  `lightpanda.dump_format` is `markdown`

#### Scenario: a custom lightpanda block is parsed

- **WHEN** the config file sets `lightpanda` to
  `{"path":"/opt/lightpanda","dump_format":"html"}`
- **THEN** the loaded configuration's `lightpanda.path` is `/opt/lightpanda` and
  its `lightpanda.dump_format` is `html`

#### Scenario: absent schedule defaults to 04:00

- **WHEN** the config file omits `schedule`
- **THEN** the loaded configuration's daily curation time is `04:00`

#### Scenario: absent retention_days defaults to 90

- **WHEN** the config file omits `retention_days`
- **THEN** the loaded configuration's `retention_days` is `90`

#### Scenario: a custom retention_days is parsed

- **WHEN** the config file sets `retention_days` to `30`
- **THEN** the loaded configuration's `retention_days` is `30`

#### Scenario: a zero retention_days disables pruning

- **WHEN** the config file sets `retention_days` to `0`
- **THEN** the loaded configuration's `retention_days` is `0` and the run
  performs no age-based prune

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
`GET /`, `GET /healthz`, and `GET /metrics` SHALL be open (not subject to this
gate). The gate is wired to `GET /download`; later changes may attach write
endpoints.

#### Scenario: protected endpoint accepts valid token

- **WHEN** a request to a protected endpoint carries the configured bearer token
- **THEN** the request proceeds normally

#### Scenario: protected endpoint rejects missing or wrong token

- **WHEN** a request to a protected endpoint carries no `Authorization` header
  or a non-matching token
- **THEN** the server responds `401` without performing the protected action

#### Scenario: open endpoints ignore credentials

- **WHEN** a client requests `GET /healthz`, `GET /`, or `GET /metrics` with no
  credentials
- **THEN** the request is served (not 401)

### Requirement: Download endpoint

The system SHALL expose `GET /download` as a protected endpoint, gated by the
existing bearer-token authentication requirement (constant-time comparison of
the configured `auth_token`). Resolution SHALL be controlled by two query
parameters: `since` (a `download` capability token) and, for first-download
bootstrap only, `kind` (`news` or `knowledge`).

Authentication SHALL precede all resolution: a request to `/download` without a
valid bearer token SHALL respond `401` without performing any resolution or
consulting the store.

When `since` is present, it SHALL be decoded to `{ kind, id }` and the token
SHALL be the sole source of kind; a `kind` parameter, if also present, SHALL be
ignored. A `since` that is empty or fails to decode SHALL respond
`400 Bad Request` with an empty body, without consulting the store.

When `since` is absent, the request is a first-download bootstrap: the server
SHALL require a `kind` parameter. If `kind` is absent or is not one of
`news`/`knowledge`, the server SHALL respond `400 Bad Request` with an empty
body, without consulting the store. If `kind` is valid, the server SHALL resolve
the download exactly as if the token were `{ kind = <kind>, id = 0 }` — the
beginning of that kind — producing the same outcomes as any other resolution.

For a valid bearer token and a resolved position `{ kind, id }`, the server
SHALL resolve the incremental download via the `download` capability: if the
resolver signals nothing-new, the server SHALL respond `204 No Content` with no
body and no `X-Next-Token` header; otherwise the server SHALL respond `200` with
`Content-Type: application/epub+zip`, the EPUB as the body, and an
`X-Next-Token` header set to the resolver's next token. The server SHALL be the
sole issuer of advance tokens (those returned in `X-Next-Token`); no advance
token is ever client-supplied.

#### Scenario: a valid token with new items returns the EPUB and a next token

- **WHEN** a client sends `GET /download?since=<token for {news,1}>` with the
  configured bearer token, against a store whose news ids are `[1, 3, 5]`
- **THEN** the server responds `200`, `Content-Type: application/epub+zip`, a
  body that is a valid EPUB of the news records with ids 3 and 5, and an
  `X-Next-Token` header that decodes to `{ news, 5 }`

#### Scenario: nothing new returns 204 and no next token

- **WHEN** a client sends `GET /download?since=<token for {news,5}>` with the
  configured bearer token, against a store whose largest news id is 5
- **THEN** the server responds `204 No Content` with no body and no
  `X-Next-Token` header

#### Scenario: a present but empty or malformed since returns 400

- **WHEN** a client sends `GET /download?since=garbage` (or an empty `since`)
  with the configured bearer token
- **THEN** the server responds `400 Bad Request` with an empty body, without
  reading the store

#### Scenario: a missing or wrong bearer token returns 401

- **WHEN** a client sends `GET /download?since=<valid token>` with no
  `Authorization` header or a non-matching token
- **THEN** the server responds `401` without resolving any download

#### Scenario: an absent since with a valid kind bootstraps from the beginning

- **WHEN** a client sends `GET /download?kind=news` (no `since`) with the
  configured bearer token, against a store whose news ids are `[1, 3, 5]`
- **THEN** the server responds `200`, `Content-Type: application/epub+zip`, a
  body that is a valid EPUB of all three news records, and an `X-Next-Token`
  header that decodes to `{ news, 5 }`

#### Scenario: a bootstrap on an empty kind returns 204

- **WHEN** a client sends `GET /download?kind=knowledge` (no `since`) with the
  configured bearer token, against a store with no knowledge records
- **THEN** the server responds `204 No Content` with no body and no
  `X-Next-Token` header

#### Scenario: a bootstrap with no kind or an unknown kind returns 400

- **WHEN** a client sends `GET /download` (no `since`, no `kind`) or
  `GET /download?kind=sports` with the configured bearer token
- **THEN** the server responds `400 Bad Request` with an empty body, without
  reading the store

#### Scenario: the kind parameter is ignored when since is present

- **WHEN** a client sends `GET /download?since=<token for {knowledge,2}>&kind=news`
  with the configured bearer token, against a store whose knowledge ids are
  `[2, 4]`
- **THEN** the server resolves `knowledge` (the token's kind), ignoring the
  `kind=news` parameter, and returns the knowledge record with id 4

### Requirement: Embedded download UI endpoint

The system SHALL serve the `ui` capability's embedded static download page at
`GET /` with `Content-Type: text/html; charset=utf-8`, returning the page bytes
verbatim with no server-side templating or substitution. This endpoint SHALL be
open (not subject to the bearer-token authentication gate), so an operator can
load it before entering the bearer token. The page makes no request requiring
authentication other than same-origin `GET /download`, which it authorizes with
a client-held bearer token.

#### Scenario: the root path serves the embedded page

- **WHEN** a client sends `GET /`
- **THEN** the server responds `200`, `Content-Type: text/html; charset=utf-8`,
  and a body equal to the `ui` capability's embedded page bytes verbatim

#### Scenario: the root path is open

- **WHEN** a client sends `GET /` with no credentials
- **THEN** the server responds `200` (not `401`)

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
(`Content-Type: text/plain; version=0.0.4`). The metric set SHALL include an
HTTP request counter and an HTTP request latency histogram keyed by method and
path, a process uptime gauge, a set of curation-run counters recorded by each
curation run that executes (a total curation-runs counter, a total
items-fetched counter, a total items-curated counter labeled by `kind` (`news`,
`knowledge`), a total source-fetch-errors counter, and a total items-pruned
counter), a per-kind EPUB-generations counter recorded by the `download`
capability's resolver each time it builds an EPUB, and the `pi`-evaluation
metrics recorded by the `longevity` capability for each actual `pi` invocation
(a total evaluations counter, a total failed-evaluations counter, and an
evaluation-latency histogram). Each counter SHALL be a monotonically
non-decreasing cumulative counter reset only on process restart, and SHALL be
emitted with a `# HELP` and `# TYPE` line even when its value is zero. The
EPUB-generations counter SHALL be labeled by `kind` (`news`, `knowledge`); the
`pi`-evaluation counters and histogram SHALL carry no label. This endpoint SHALL
NOT require authentication so a scraper can poll it. The curation-run counters
reflect only curation runs driven through the `curation-job` capability; the
EPUB-generation counter reflects only EPUBs built by the `download`
capability's resolver; and the `pi`-evaluation metrics reflect only actual
`pi` invocations of the `longevity` evaluator (a cache hit is not an
evaluation).

#### Scenario: metrics are exposed in Prometheus text format

- **WHEN** a client sends `GET /metrics`
- **THEN** the response has Content-Type
  `text/plain; version=0.0.4` and a body containing at least the request
  counter, the latency histogram, the uptime gauge, the curation-run counter
  families, the per-kind EPUB-generations counter, and the `pi`-evaluation
  counter and histogram families

#### Scenario: requests increment the counter

- **WHEN** two `GET /healthz` requests are served, then `GET /metrics` is read
- **THEN** the request counter reflects at least those two healthz requests for
  `method=GET,path=/healthz`

#### Scenario: metrics endpoint is open

- **WHEN** a client sends `GET /metrics` with no credentials
- **THEN** the server responds `200` with the exposition body (not 401)

#### Scenario: a curation run increments the curation counters

- **WHEN** a curation run executes that fetches three items, stores two under
  `news` and one under `knowledge`, fails one source, and prunes two records,
  then `GET /metrics` is read
- **THEN** the exposition shows the curation-runs counter incremented by one,
  the items-fetched counter incremented by three, the items-curated counter for
  `kind=news` incremented by two and for `kind=knowledge` by one, the
  source-fetch-errors counter incremented by one, and the items-pruned counter
  incremented by two

#### Scenario: curation counters are cumulative across runs

- **WHEN** two curation runs execute in the same process, then `GET /metrics` is
  read
- **THEN** the curation-runs counter reports two and the items counters report
  the sum of both runs' items, not the value of the most recent run alone

#### Scenario: counters are emitted at zero before any run

- **WHEN** a client sends `GET /metrics` before any curation run, download, or
  `pi` evaluation has occurred in the process
- **THEN** the exposition still contains the EPUB-generations counter for each
  kind, the `pi`-evaluation counters, and the `pi`-evaluation histogram
  (`_count 0`), each with value zero, so a scraper observes every family exists

#### Scenario: an EPUB download increments the per-kind generation counter

- **WHEN** a `GET /download` for kind `news` resolves a non-empty range and
  streams an EPUB, and a `GET /download` for kind `knowledge` also resolves a
  non-empty range, then `GET /metrics` is read
- **THEN** the `curation_epub_generations_total` counter for `kind="news"` is
  incremented by one and for `kind="knowledge"` by one, and a download that
  resolves nothing new (`204`) increments neither

#### Scenario: a pi evaluation increments the count and records latency

- **WHEN** the longevity evaluator invokes `pi` for an item that is not in its
  cache and `pi` returns a parseable label, then `GET /metrics` is read
- **THEN** the `curation_pi_evaluations_total` counter is incremented by one,
  the `curation_pi_evaluations_failed_total` counter is unchanged, and the
  `curation_pi_evaluation_duration_seconds` histogram reflects one observation

#### Scenario: a failed pi evaluation increments the failure counter

- **WHEN** the longevity evaluator invokes `pi` and the invocation errors or its
  output is unparseable, then `GET /metrics` is read
- **THEN** the `curation_pi_evaluations_total` counter and the
  `curation_pi_evaluations_failed_total` counter are each incremented by one

#### Scenario: a cache hit is not counted as a pi evaluation

- **WHEN** the longevity evaluator classifies an item found in its cache (no
  `pi` invocation), then `GET /metrics` is read
- **THEN** neither `curation_pi_evaluations_total` nor the histogram count
  changes, because no `pi` invocation occurred

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

### Requirement: Configuration bootstrap command

The system SHALL provide a `curation init` command that writes a default
configuration to the resolved configuration path — the same XDG / `--config` /
`CURATION_CONFIG` resolution used by `serve` — with a generated `auth_token`,
creating the configuration directory if it does not exist. The generated token
SHALL be opaque and randomly chosen. Every configuration field other than
`auth_token` SHALL take its default value. If a configuration file already
exists at the resolved path, the command SHALL write nothing, report the
existing path, and exit non-zero, unless `--force` is given; with `--force` it
SHALL overwrite the existing file with a fresh default configuration and a
newly generated token. On success the command SHALL print the written path, the
generated token, and a short next-steps message, and SHALL exit zero. The
command SHALL be non-interactive, SHALL perform no source acquisition (no HTTP
fetch, no Lightpanda or `pi` subprocess, no curation run), and SHALL not start
the server. The written configuration SHALL be loadable by the configuration
loader.

#### Scenario: init writes a default config with a generated token

- **WHEN** the operator runs `curation init` with no existing configuration at
  the resolved path
- **THEN** a configuration file is written at the resolved path whose
  `auth_token` is non-empty and whose every other field equals its default, and
  the command exits 0

#### Scenario: init creates a missing configuration directory

- **WHEN** the resolved configuration path's parent directory does not exist
- **THEN** `curation init` creates that directory and writes the configuration
  there

#### Scenario: init refuses to overwrite an existing configuration

- **WHEN** the operator runs `curation init` and a configuration already exists
  at the resolved path (and `--force` is not given)
- **THEN** the command writes nothing, reports the existing path, and exits
  non-zero

#### Scenario: --force overwrites an existing configuration

- **WHEN** the operator runs `curation init --force` and a configuration already
  exists at the resolved path
- **THEN** the command overwrites the file with a fresh default configuration
  and a newly generated token, and exits 0

#### Scenario: init honors the same path resolution as serve

- **WHEN** `--config <path>` is given, or `CURATION_CONFIG` is set, or neither
  and the XDG default applies
- **THEN** `curation init` writes to the same path `curation serve` would read
  — flag taking precedence over environment, environment over the XDG default

#### Scenario: init is non-interactive and performs no acquisition

- **WHEN** the operator runs `curation init`
- **THEN** it performs no HTTP fetch, spawns no Lightpanda or `pi` subprocess,
  runs no curation job, and starts no server

#### Scenario: the written configuration round-trips through the loader

- **WHEN** `curation init` has written a configuration
- **THEN** the configuration loader loads it successfully with the generated
  `auth_token` preserved and defaults for every other field

#### Scenario: init prints the path, token, and next steps

- **WHEN** `curation init` writes a configuration successfully
- **THEN** it prints the written path, the generated token, and a next-steps
  message naming `import` (to add sources) and `serve` (to run)

