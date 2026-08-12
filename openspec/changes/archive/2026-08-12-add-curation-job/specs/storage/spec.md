## ADDED Requirements

### Requirement: Concurrent append and range access

The system SHALL serialize mutation and range reads of the store with an
internal mutex so that one writer (a curation run appending records) MAY proceed
concurrently with one or more reader threads (the `/download` serving path
calling `range`) without a data race. Both `append` and `range` SHALL hold the
mutex for the duration of their access to the records list, the per-kind id
lists, and the next-id counter. The mutex SHALL introduce no change to the file
format, to the global-monotonic id assignment, to the append-only one-line-per
-record invariant, or to the half-open `(since_id, …]` semantics of `range`. A
reader SHALL observe a consistent snapshot: it SHALL never see a record whose id
has been assigned but whose index entry has not, and SHALL never observe a
partially appended record.

#### Scenario: a concurrent append and range do not race

- **WHEN** a writer appends a `news` record while a reader calls
  `range(.news, 0)` on another thread
- **THEN** both complete without a data race and the reader observes either the
  store's state just before or just after the append, never a torn or
  half-indexed record

#### Scenario: range observes a consistent snapshot

- **WHEN** a reader calls `range(.knowledge, 0)` while appends to the
  `knowledge` index are concurrent
- **THEN** every id the reader observes is present in the index and every index
  entry the reader observes has a corresponding record

#### Scenario: the file format and id semantics are unchanged

- **WHEN** records are appended under concurrent access
- **THEN** each appended record is still written as exactly one self-contained
  JSONL line, ids are still assigned strictly increasing and never reused, and
  `range` remains half-open on the lower bound
