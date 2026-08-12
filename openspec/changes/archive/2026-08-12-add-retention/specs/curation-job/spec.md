## MODIFIED Requirements

### Requirement: One curation run

The system SHALL provide a synchronous curation run that, given a list of feed
sources, a list of web-content sources, a Lightpanda configuration, the curation
rules, a `pi` longevity configuration, an HTTP client, an evaluation cache, a
`pi` invoker, a store, a log writer, and a retention window in days (zero
disables pruning), performs exactly one end-to-end pass: it SHALL acquire each
configured feed source (fetch and parse) via the `sources` capability; it SHALL
acquire each configured web-content source (render via the Lightpanda headless
browser) via the `sources` capability; it SHALL gather all extracted items
across both kinds of sources; it SHALL run the `curation` capability's pure
pipeline (dedupe, filter, tag, cap) over the union; for each surviving curated
item it SHALL classify its longevity via the `longevity` capability to obtain a
stream `Kind`; and it SHALL append each survivor to the store via the `storage`
capability under that `Kind`. When the retention window is greater than zero,
the run SHALL, after appending the survivors, prune the store via the `storage`
capability's age-based prune operation, removing records older than the window
measured against the run's wall-clock time; when the window is zero the run
SHALL perform no prune. The run SHALL return a summary carrying at least the
number of sources seen (feed sources plus web-content sources), the number of
items fetched, the number of curated survivors, the number of items stored per
`Kind` (`news`, `knowledge`), the number of sources that failed, and the number
of records pruned by retention (`pruned`, zero when pruning is disabled or
nothing was old enough). The run SHALL treat a web-content item no differently
from a feed item once acquired — both flow through the same pipeline,
classification, and storage. The run SHALL perform no longevity evaluation of
its own (it obtains the `Kind` solely from the `longevity` capability) and SHALL
perform no HTTP serving, no daily scheduling, and no token encoding or EPUB
generation.

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
