# curation-job Specification

## Purpose
TBD - created by archiving change add-curation-job. Update Purpose after archive.
## Requirements
### Requirement: One curation run

The system SHALL provide a synchronous curation run that, given a list of feed
sources, a list of web-content sources, a Lightpanda configuration, the curation
rules, a `pi` longevity configuration, an HTTP client, an evaluation cache, a
`pi` invoker, a store, a log writer, an optional metrics recorder, and a
retention window in days (zero disables pruning), performs exactly one
end-to-end pass: it SHALL acquire each configured feed source (fetch and parse)
via the `sources` capability; it SHALL acquire each configured web-content
source (render via the Lightpanda headless browser) via the `sources`
capability; it SHALL gather all extracted items across both kinds of sources; it
SHALL run the `curation` capability's pure pipeline (dedupe, filter, tag, cap)
over the union; for each surviving curated item it SHALL classify its longevity
via the `longevity` capability to obtain a stream `Kind`; and it SHALL append
each survivor to the store via the `storage` capability under that `Kind`. When
the retention window is greater than zero, the run SHALL, after appending the
survivors, prune the store via the `storage` capability's age-based prune
operation, removing records older than the window measured against the run's
wall-clock time; when the window is zero the run SHALL perform no prune. When a
non-null metrics recorder is provided, the run SHALL, after appending the
survivors (and pruning, if any), record its run metrics into the recorder: one
run, the number of items fetched, the number of items stored per `Kind` (`news`,
`knowledge`), the number of sources that failed, and the number of records
pruned; when the recorder is null the run SHALL record nothing. A recording
failure SHALL be logged and SHALL NOT abort the run or the storage of survivors.
The run SHALL return a summary carrying at least the number of sources seen
(feed sources plus web-content sources), the number of items fetched, the number
of curated survivors, the number of items stored per `Kind` (`news`,
`knowledge`), the number of sources that failed, and the number of records
pruned by retention (`pruned`, zero when pruning is disabled or nothing was old
enough). The run SHALL treat a web-content item no differently from a feed item
once acquired — both flow through the same pipeline, classification, and
storage. The run SHALL perform no longevity evaluation of its own (it obtains
the `Kind` solely from the `longevity` capability) and SHALL perform no HTTP
serving, no daily scheduling, and no token encoding or EPUB generation.

#### Scenario: a run stores each survivor under its classified kind

- **WHEN** a run is given two feed sources whose items, after the pipeline, leave
  three survivors, and the longevity classifier returns `news` for two and
  `knowledge` for one
- **THEN** the store gains exactly three records — two of `kind` `news` and one
  of `kind` `knowledge` — and the returned summary reports `news = 2` and
  `knowledge = 1`

#### Scenario: a run acquires web sources alongside feed sources

- **WHEN** a run is given one feed source (yielding one item) and one web-content
  source (yielding one item), both surviving the pipeline, and the longevity
  classifier returns `knowledge` for both
- **THEN** the store gains two records of `kind` `knowledge`, the returned
  summary reports `sources = 2` and `knowledge = 2`, and both items are stored
  under the same kind regardless of which source kind produced them

#### Scenario: a run passes the configured cap to the pipeline

- **WHEN** a run is given a configuration whose per-run `cap` is `2` and five
  items would otherwise survive
- **THEN** the pipeline returns at most two survivors and the store gains at
  most two records

#### Scenario: a run prunes old records when a retention window is set

- **WHEN** a run is given a retention window of `90` days and, before the run,
  the store holds one record dated 100 days ago and one record dated 10 days
  ago, and the run appends no new survivor older than the window
- **THEN** the 100-day-old record is removed, the 10-day-old record and any new
  survivors remain, and the returned summary reports `pruned = 1`

#### Scenario: a run with a zero retention window prunes nothing

- **WHEN** a run is given a retention window of `0` and the store holds records
  far older than any window
- **THEN** no record is removed and the returned summary reports `pruned = 0`

#### Scenario: an empty source list stores nothing

- **WHEN** a run is given no feed sources and no web-content sources but a
  non-zero retention window, and the store holds an old record
- **THEN** it fetches and renders nothing, classifies nothing, appends nothing,
  still prunes the old record, and reports the prune in the summary

#### Scenario: a run records its summary metrics

- **WHEN** a run is given a non-null metrics recorder, fetches three items,
  stores two under `news` and one under `knowledge`, fails no sources, and prunes
  nothing
- **THEN** after the run the recorder reflects one run, three items fetched, two
  items curated of kind `news`, one item curated of kind `knowledge`, zero
  source fetch errors, and zero items pruned

#### Scenario: a run without a recorder records nothing

- **WHEN** a run is given a null metrics recorder
- **THEN** the run completes and returns its summary unchanged, and no metrics
  are recorded by the run

### Requirement: Per-source error isolation

The system SHALL isolate each source's acquisition so that a network error, a
non-2xx status, a timeout, a parse failure, or a web-content render failure (a
missing Lightpanda binary, a non-zero exit, a render timeout, or an empty
captured output) for one source SHALL be reported as a failure of that source
only: the run SHALL log it, count it in the summary's failed-sources count, and
continue acquiring the remaining sources. A failing source SHALL NOT cause the
run to observe partial items from that source, and SHALL NOT abort the run or the
storage of survivors from other sources. A `pi` classification failure is NOT a
source failure (it is absorbed by the `longevity` capability's fallback) and
SHALL NOT be counted as a failed source.

#### Scenario: a failing source is skipped and the run continues

- **WHEN** a run is given three sources of which the second fails to fetch and
  the other two each yield survivors
- **THEN** the run stores the survivors of the first and third sources, the
  summary's failed-sources count is `1`, and the run does not abort

#### Scenario: a failing web source is skipped and the run continues

- **WHEN** a run is given one feed source (yielding a survivor) and one
  web-content source whose render fails (the Lightpanda binary is missing)
- **THEN** the run stores the feed source's survivor, the summary's
  failed-sources count is `1`, and the run does not abort

#### Scenario: a parse failure for one source does not lose another's items

- **WHEN** a run is given two sources and the first yields a feed that fails to
  parse while the second yields two survivors
- **THEN** the store gains the two survivors from the second source and the
  summary's failed-sources count is `1`

#### Scenario: a pi failure is not counted as a failed source

- **WHEN** a survivor's `pi` classification fails (so the `longevity` capability
  returns its fallback `Kind`) during a run whose every source fetched and parsed
- **THEN** the summary's failed-sources count is `0` and the survivor is still
  stored under the fallback `Kind`

### Requirement: One run at a time

The system SHALL serialize curation runs so that at most one run executes at any
instant, preventing two overlapping runs from appending the same items twice. It
SHALL expose this as a non-blocking probe `tryRun` using the same inputs as a run
that returns either `.ran` with the run summary when it started and completed a
run, or `.busy` when a run was already in progress. A `.busy` result SHALL start
no run, SHALL append nothing, and SHALL perform no fetching, classification, or
storage. The serialization SHALL hold only while a run is in progress and SHALL
not be held across the lifetime of the process.

#### Scenario: a second concurrent probe is busy and appends nothing

- **WHEN** `tryRun` is called while another run is in progress
- **THEN** it returns `.busy`, starts no run, and the store is not mutated by the
  second probe

#### Scenario: a probe after a run completes starts a fresh run

- **WHEN** a run completes and `tryRun` is called again
- **THEN** it returns `.ran` with a new summary and performs a full new pass

#### Scenario: busy never fetches or classifies

- **WHEN** `tryRun` returns `.busy`
- **THEN** no source is fetched, no `pi` invocation occurs, and no record is
  appended

### Requirement: Capability boundary

The `curation-job` capability SHALL own only the end-to-end orchestration of one
curation run and its one-at-a-time serialization. It SHALL own no HTTP serving,
no daily scheduling, no feed fetching or parsing internals (it acquires each
source through the `sources` capability), no longevity evaluation internals (it
obtains a `Kind` through the `longevity` capability), no token codec, no EPUB
generation, and no storage internals (it mutates the store only through the
`storage` capability's append and age-based prune operations). It SHALL be
invokable as a library.

#### Scenario: the job owns no serving, scheduling, or internals

- **WHEN** a run and `tryRun` execute
- **THEN** they perform no HTTP serving, no daily scheduling, no direct feed
  fetch or parse, no direct `pi` subprocess spawn, no token encode/decode, no
  EPUB generation, and mutate the store only through the `storage` capability's
  append and age-based prune operations

#### Scenario: the job is invokable as a library

- **WHEN** a caller invokes the run with injected dependencies and a stubbed
  `pi` invoker
- **THEN** the run completes and returns a summary without binding a port,
  starting a scheduler, or spawning a real `pi` process

