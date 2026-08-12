## ADDED Requirements

### Requirement: Stored item record

The system SHALL persist a curated item as a `Record` carrying a global
monotonic `id` (`u64`), a stream `kind` (`news` or `knowledge`), and the
curated item fields `title`, `url`, `body`, `date`, `source`, and `tags`. A
record SHALL be a plain value and SHALL hold no I/O, scheduling, network, or
process state. The `kind` SHALL be one of the two stream kinds produced by the
longevity capability; the store SHALL NOT perform longevity evaluation.

#### Scenario: a record carries id, kind, and the curated fields

- **WHEN** a curated item with title `T`, url `U`, body `B`, date `D`, source
  `S`, tags `["ai"]` is stored as kind `knowledge`
- **THEN** the stored record carries those field values, `kind` `knowledge`,
  and an `id` of type `u64`

#### Scenario: the store performs no longevity evaluation

- **WHEN** the store appends a record
- **THEN** it assigns the kind it was given and does not invoke `pi` or any
  other longevity evaluator

### Requirement: Append-only JSONL item log

The system SHALL persist records in an append-only JavaScript Object Notation
Lines (JSONL) file at `$XDG_DATA_HOME/curation/items.jsonl` (resolving to
`~/.local/share/curation/items.jsonl` when `XDG_DATA_HOME` is unset), one
`std.json` object per line. The file SHALL be the single source of truth. A
record SHALL be written by appending exactly one line terminated by a newline;
existing lines SHALL NOT be edited, reordered, or rewritten. When the file does
not exist it SHALL be treated as an empty store and created lazily on the first
append.

#### Scenario: each append writes one JSON line

- **WHEN** two records are appended to a store backed by an empty file
- **THEN** the file contains exactly two lines, each a decodable JSON object
  carrying the appended record's fields

#### Scenario: a missing file is an empty store

- **WHEN** a store is loaded against a path whose file does not exist
- **THEN** the store is empty (zero records) and the first append creates the
  file

#### Scenario: appends do not mutate prior records

- **WHEN** a record is appended after other records already exist
- **THEN** the bytes of the previously written lines are unchanged

### Requirement: Global monotonic id assignment

The system SHALL assign each appended record a global monotonic `id` that is
strictly greater than every previously assigned id, that is never reused, and
that is stable across process restarts. The next id SHALL be derived on load as
one greater than the largest id present among valid records (or `1` when the
store is empty). `append` SHALL assign this next id to the record, return it to
the caller, and advance the counter.

#### Scenario: ids are assigned in increasing order

- **WHEN** three records are appended to an empty store
- **THEN** they are assigned ids `1`, `2`, and `3` in append order

#### Scenario: the id counter survives a restart

- **WHEN** a store whose largest assigned id is `7` is closed and reopened
- **THEN** the next appended record receives id `8`

#### Scenario: ids are never reused after a torn tail

- **WHEN** a store's largest valid id is `5` and its trailing line is torn and
  ignored on reload
- **THEN** the next appended record receives id `6`, not an id derived from the
  torn line

### Requirement: In-memory per-kind index rebuilt on startup

On load the system SHALL replay the JSONL file line by line, decoding each line
into a `Record` with `std.json`, and SHALL rebuild an in-memory index mapping
each kind (`news`, `knowledge`) to the ascending list of its record ids, and
SHALL restore the next-id counter from the largest valid id. A line that does
not decode as a valid `Record` SHALL terminate replay; that line and any lines
after it SHALL be ignored for index and counter purposes without aborting the
load. The index SHALL make a range lookup by kind an index slice rather than a
full scan.

#### Scenario: replay rebuilds the per-kind index

- **WHEN** a store is loaded whose file contains a `news` record at id 1, a
  `knowledge` record at id 2, and a `news` record at id 3
- **THEN** the index maps `news` to ids `[1, 3]` and `knowledge` to ids `[2]`

#### Scenario: a torn trailing line is ignored without aborting

- **WHEN** a store is loaded whose file has two valid lines followed by a third
  partial line that does not decode
- **THEN** the load succeeds, the two valid records are indexed, and the partial
  line is ignored

#### Scenario: an empty file yields an empty index

- **WHEN** a store is loaded against an empty file
- **THEN** both per-kind id lists are empty and the next-id counter is `1`

### Requirement: Kind and id range query

The system SHALL provide a range query that, given a `kind` and a `since_id`,
returns the records of that kind whose `id` is strictly greater than
`since_id`, in ascending id order. The range SHALL be half-open on the lower
bound — a record whose id equals `since_id` SHALL NOT be included. When no
record of the given kind has an id greater than `since_id`, the result SHALL be
empty. The query SHALL consider only records of the requested kind and SHALL
not leak records of the other kind.

#### Scenario: range returns later items of one kind

- **WHEN** a store has `news` ids `[1, 3, 5]` and `range(.news, 1)` is called
- **THEN** it returns the `news` records with ids `3` and `5`, in that order

#### Scenario: range is half-open on the lower bound

- **WHEN** `range(.news, 3)` is called on a store with `news` ids `[1, 3, 5]`
- **THEN** it returns only the `news` record with id `5`

#### Scenario: range yields nothing when current

- **WHEN** `range(.news, 5)` is called on a store whose largest `news` id is `5`
- **THEN** the result is empty

#### Scenario: range never returns the other kind

- **WHEN** `range(.knowledge, 0)` is called on a store that has both `news` and
  `knowledge` records
- **THEN** the result contains only `knowledge` records

#### Scenario: since_id of zero returns all of the kind

- **WHEN** `range(.news, 0)` is called on a store with `news` ids `[1, 3, 5]`
- **THEN** it returns all three `news` records in ascending id order

### Requirement: Crash-safe appends

The system SHALL write each record as one self-contained JSON line and SHALL
flush that line to the operating system before `append` returns, so an
interrupted process loses at most the line being written and never a previously
flushed record. A later reload SHALL tolerate such a torn trailing line by
stopping replay at it (per the in-memory index requirement) without lowering
any assigned id.

#### Scenario: a completed append survives an abrupt close

- **WHEN** a record is appended and flushed, then the process exits without a
  graceful close, then the store is reloaded
- **THEN** the appended record is present and indexed

#### Scenario: a torn trailing line does not corrupt earlier ids

- **WHEN** a store file's last line is partially written (not decodable) and the
  store is reloaded
- **THEN** all records before the torn line are present and indexed, and the
  next assigned id is one greater than the largest valid id

### Requirement: Capability boundary

The store capability SHALL own record persistence and the per-kind range query
only. It SHALL perform no feed fetching, no curation pipeline stage, no
longevity evaluation, no HTTP serving, no daily scheduling, no token encoding
or decoding, no EPUB generation, and no age-based retention. It SHALL be
invokable as a library.

#### Scenario: the store owns no serving, scheduling, or evaluation

- **WHEN** the store appends and ranges records
- **THEN** it performs no HTTP serving, no daily scheduling, no `pi`
  invocation, no token parsing, and no EPUB generation

#### Scenario: the store owns no retention

- **WHEN** records older than any age threshold exist in the store
- **THEN** the store does not delete or prune them in this capability
