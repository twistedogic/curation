## ADDED Requirements

### Requirement: One curation run

The system SHALL provide a synchronous curation run that, given a list of feed
sources, the curation rules, a `pi` longevity configuration, an HTTP client, an
evaluation cache, a `pi` invoker, a store, and a log writer, performs exactly
one end-to-end pass: it SHALL acquire each configured feed source (fetch and
parse) via the `sources` capability; it SHALL gather all extracted items across
sources; it SHALL run the `curation` capability's pure pipeline (dedupe, filter,
tag, cap) over the union; for each surviving curated item it SHALL classify its
longevity via the `longevity` capability to obtain a stream `Kind`; and it SHALL
append each survivor to the store via the `storage` capability under that
`Kind`. The run SHALL return a summary carrying at least the number of sources
seen, the number of items fetched, the number of curated survivors, the number
of items stored per `Kind` (`news`, `knowledge`), and the number of sources that
failed. The run SHALL perform no longevity evaluation of its own (it obtains the
`Kind` solely from the `longevity` capability) and SHALL perform no HTTP serving,
no daily scheduling, and no token encoding or EPUB generation.

#### Scenario: a run stores each survivor under its classified kind

- **WHEN** a run is given two feed sources whose items, after the pipeline, leave
  three survivors, and the longevity classifier returns `news` for two and
  `knowledge` for one
- **THEN** the store gains exactly three records — two of `kind` `news` and one
  of `kind` `knowledge` — and the returned summary reports `news = 2` and
  `knowledge = 1`

#### Scenario: a run passes the configured cap to the pipeline

- **WHEN** a run is given a configuration whose per-run `cap` is `2` and five
  items would otherwise survive
- **THEN** the pipeline returns at most two survivors and the store gains at most
  two records

#### Scenario: an empty source list stores nothing

- **WHEN** a run is given no sources
- **THEN** it fetches nothing, classifies nothing, appends nothing, and returns a
  summary whose counts are all zero

### Requirement: Per-source error isolation

The system SHALL isolate each source's acquisition so that a network error, a
non-2xx status, a timeout, or a parse failure for one source SHALL be reported
as a failure of that source only: the run SHALL log it, count it in the summary's
failed-sources count, and continue acquiring the remaining sources. A failing
source SHALL NOT cause the run to observe partial items from that source, and
SHALL NOT abort the run or the storage of survivors from other sources. A
`pi` classification failure is NOT a source failure (it is absorbed by the
`longevity` capability's fallback) and SHALL NOT be counted as a failed source.

#### Scenario: a failing source is skipped and the run continues

- **WHEN** a run is given three sources of which the second fails to fetch and
  the other two each yield survivors
- **THEN** the run stores the survivors of the first and third sources, the
  summary's failed-sources count is `1`, and the run does not abort

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
generation, and no storage internals (it appends through the `storage`
capability and mutates the store only via that capability's append). It SHALL be
invokable as a library.

#### Scenario: the job owns no serving, scheduling, or internals

- **WHEN** a run and `tryRun` execute
- **THEN** they perform no HTTP serving, no daily scheduling, no direct feed
  fetch or parse, no direct `pi` subprocess spawn, no token encode/decode, no
  EPUB generation, and mutate the store only through the `storage` capability's
  append

#### Scenario: the job is invokable as a library

- **WHEN** a caller invokes the run with injected dependencies and a stubbed
  `pi` invoker
- **THEN** the run completes and returns a summary without binding a port,
  starting a scheduler, or spawning a real `pi` process
