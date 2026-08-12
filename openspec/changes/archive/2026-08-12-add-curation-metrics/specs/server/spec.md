## MODIFIED Requirements

### Requirement: Prometheus metrics endpoint

The system SHALL expose `GET /metrics` returning a Prometheus text exposition
(`Content-Type: text/plain; version=0.0.4`). The metric set SHALL include an
HTTP request counter and an HTTP request latency histogram keyed by method and
path, a process uptime gauge, and a set of curation-run counters recorded by
each curation run that executes: a total curation-runs counter, a total
items-fetched counter, a total items-curated counter labeled by `kind`
(`news`, `knowledge`), a total source-fetch-errors counter, and a total
items-pruned counter. Each curation counter SHALL be a monotonically
non-decreasing cumulative counter reset only on process restart, and SHALL be
emitted with a `# HELP` and `# TYPE counter` line even when its value is zero.
This endpoint SHALL NOT require authentication so a scraper can poll it. The
curation counters reflect only curation runs driven through the `curation-job`
capability; per-kind EPUB generations and `pi`-evaluation count, latency, and
failures are out of scope for this metric set.

#### Scenario: metrics are exposed in Prometheus text format

- **WHEN** a client sends `GET /metrics`
- **THEN** the response has Content-Type
  `text/plain; version=0.0.4` and a body containing at least the request
  counter, the latency histogram, the uptime gauge, and the curation-run counter
  families

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

- **WHEN** a client sends `GET /metrics` before any curation run has executed in
  the process
- **THEN** the exposition still contains every curation counter family with a
  value of zero, so a scraper observes the family exists
