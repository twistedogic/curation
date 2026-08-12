## 1. Record model

- [x] 1.1 Add `src/store.zig` defining `Record` with `id: u64`, `kind`
  (`news`/`knowledge`), and the curated fields `title`, `url`, `body`, `date`,
  `source`, `tags`; a plain value type.
- [x] 1.2 Self-check: a `Record` round-trips through `std.json` (encode → decode
  yields equal fields; `id` and `kind` preserved) (spec: Stored item record).

## 2. Append-only JSONL log with monotonic id

- [x] 2.1 Implement `Store` over a JSONL file at the resolved XDG data path,
  with `append(store, kind, item) -> id` that assigns the next monotonic id,
  serializes one `std.json` line, and flushes it (design D1/D2).
- [x] 2.2 Self-check: appending to a missing path creates the file and writes
  one line per record; three appends to an empty store yield ids 1, 2, 3;
  prior lines are byte-unchanged by a later append (spec: Append-only JSONL
  item log, Global monotonic id assignment).

## 3. In-memory index and replay on startup

- [x] 3.1 Implement `load(gpa, io, path) -> Store` that replays the file line by
  line, rebuilding the per-kind ascending id index and the next-id counter
  (`max valid id + 1`, or `1` when empty); a missing file is an empty store
  (design D3/D4).
- [x] 3.2 Self-check: after a close-and-reload, the per-kind index is rebuilt
  and the next appended id continues the sequence (id 8 follows a largest
  valid id of 7) (spec: In-memory per-kind index rebuilt on startup, Global
  monotonic id assignment).

## 4. Kind and id range query

- [x] 4.1 Implement `range(store, kind, since_id) -> []Record` returning the
  records of `kind` with `id > since_id` in ascending id order, using the
  per-kind index (design D4).
- [x] 4.2 Self-check: a store with `news` ids [1,3,5] and a `knowledge` id [2]
  yields `range(.news,1)` = ids 3,5; `range(.news,3)` = id 5 (half-open);
  `range(.news,5)` = empty; `range(.news,0)` = ids 1,3,5; `range(.knowledge,0)`
  returns only the knowledge record (spec: Kind and id range query).

## 5. Crash-safe appends and torn-tail tolerance

- [x] 5.1 Make each `append` a single self-contained, flushed line, so an
  interrupted process loses at most the trailing line (design D2/D5).
- [x] 5.2 Self-check: a file with two valid lines plus a torn (non-decodable)
  trailing line loads successfully, indexes the two valid records, and assigns
  the next id as 3 (one greater than the largest valid id) (spec: Crash-safe
  appends, In-memory per-kind index rebuilt on startup).

## 6. Integration

- [x] 6.1 Register the new module in `main.zig`'s comptime test import block so
  `zig build test` discovers it.
- [x] 6.2 `zig build test` green.
