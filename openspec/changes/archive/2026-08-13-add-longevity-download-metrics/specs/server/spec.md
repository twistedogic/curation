## MODIFIED Requirements

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
