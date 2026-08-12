## ADDED Requirements

### Requirement: Age-based retention prune

The store SHALL provide an age-based prune operation
`pruneByAge(now_epoch_seconds, max_age_seconds) -> pruned_count` that removes
from the store every record whose `date` field, when parsed as an ISO-8601 /
RFC-3339 date-time or an RFC-822 date-time, denotes an instant strictly older
than `now_epoch_seconds - max_age_seconds`. A record whose `date` is empty or
cannot be parsed into one of those formats SHALL be kept (it SHALL NOT be
pruned). The prune SHALL rewrite the JSONL log atomically (write every
surviving record to a sibling temporary file in the same directory, then
atomically replace the store file), SHALL rebuild the in-memory `records` list
and the per-kind id indexes (`news`, `knowledge`) from exactly the survivors,
and SHALL leave `next_id` unchanged so global monotonic ids are never reused or
decremented. The prune SHALL hold the store's mutation/read mutex across its
entire duration and SHALL return the number of records removed. It SHALL
perform no fetching, no longevity evaluation, no HTTP serving, no scheduling,
no token encoding or decoding, and no EPUB generation. The store's date parsing
is limited to ISO-8601 / RFC-3339 and RFC-822; any other format yields an
unparseable (kept) record.

#### Scenario: records older than the window are removed

- **WHEN** the store holds two records whose parsed dates are 100 and 10 days
  before `now`, and `pruneByAge(now, 90 * 86400)` is called
- **THEN** the 100-day-old record is removed, the 10-day-old record remains,
  and the returned count is `1`

#### Scenario: undated or unparseable records are kept

- **WHEN** the store holds a record whose `date` is empty and a record whose
  `date` is `Tue, 99 Zzz 9999 NotaDate`, and `pruneByAge` is called with any
  window
- **THEN** neither record is removed and the returned count is `0`

#### Scenario: ISO-8601 and RFC-822 dates are both accepted

- **WHEN** the store holds two equally old records, one dated
  `2024-01-01T00:00:00Z` and one dated `Mon, 01 Jan 2024 00:00:00 GMT`, and
  `pruneByAge` is called with a window that makes them old
- **THEN** both records are removed

#### Scenario: ids are never reused after a prune

- **WHEN** the store has assigned ids `[1, 2, 3]`, record `2` is pruned, and a
  new record is appended
- **THEN** the new record receives id `4` (not `2`), and `next_id` is unchanged
  by the prune

#### Scenario: the on-disk log matches the survivors after a prune

- **WHEN** `pruneByAge` removes some records and the store is reloaded from its
  file path
- **THEN** the reloaded store holds exactly the surviving records, in ascending
  id order, with no pruned record present

#### Scenario: prune is serialized with appends and range reads

- **WHEN** a prune is in progress
- **THEN** a concurrent `append` or `range` read blocks until the prune
  releases the mutex, and neither observes a half-rewritten log or index

## MODIFIED Requirements

### Requirement: Capability boundary

The store capability SHALL own record persistence, the per-kind range query,
and age-based retention pruning of its own records. It SHALL perform no feed
fetching, no curation pipeline stage, no longevity evaluation, no HTTP serving,
no daily scheduling, no token encoding or decoding, and no EPUB generation. It
SHALL be invokable as a library.

#### Scenario: the store owns no serving, scheduling, or evaluation

- **WHEN** the store appends, ranges, and prunes records
- **THEN** it performs no HTTP serving, no daily scheduling, no `pi`
  invocation, no token parsing, and no EPUB generation

#### Scenario: the store owns no retention

- **WHEN** records older than an age threshold exist in the store
- **THEN** the store removes them through its own `pruneByAge` operation,
  rewriting its log and rebuilding its index, and exposes no other deletion path
