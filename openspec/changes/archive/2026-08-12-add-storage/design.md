## Context

`curation` has the server bedrock (config, lifecycle, `/healthz`, auth gate,
logging, `/metrics`), the pure curation pipeline ending at cap, feed
fetching + parsing, and the `pi` longevity evaluator that maps each surviving
item to a stream `Kind` (`news`/`knowledge`). `.see/intent.md` fixes the full
pipeline order as normalize → dedupe → filter → tag → cap → longevity
evaluation (FR-15) → route to news/knowledge stream → **store** (FR-5), and
specifies the storage design directly: FR-6 — "a durable, append-only JSONL
item log (one record per line via `std.json`) persists items, each tagged with
a global monotonic id and a kind (news/knowledge). An in-memory index (rebuilt
on startup) maps each kind → sorted ids for range lookup." The token semantics
(FR-9) are defined against this id: a token is `base64("<kind>:<global_id>")`
and the range query is `kind = token.kind AND id > token.id`. The `longevity`
design explicitly defers storage as a later change that "consume[s] the kind
this evaluator produces."

This change adds that store and nothing more. It is the next slice in
data-flow order, and it is deliberately an I/O boundary only: it durably
records a labeled item and answers a kind+id range. Scheduling/daily job
(US-002), EPUB generation/download (FR-8, US-004), token encode/decode (FR-9),
retention prune (FR-16), and the web UI (US-007) are all later changes that
read or drive this store.

## Goals / Non-Goals

**Goals:**
- A `Record` value: the curated item fields (`title`, `url`, `body`, `date`,
  `source`, `tags`) plus a `kind` (`news`/`knowledge`) and a `id`
  (`u64`, global and monotonic). Records are plain values.
- A `Store` over a JSONL file at `$XDG_DATA_HOME/curation/items.jsonl`
  (`~/.local/share/curation/` when unset), where each line is one `Record`
  serialized via `std.json`.
- `load(gpa, io, path) -> Store`: opens the file and replays it to restore the
  next-id counter and the per-kind in-memory id index; a missing file is an
  empty store (the file is created lazily on first append).
- `append(store, kind, item) -> id`: assigns the next id, serializes one JSONL
  line, flushes it, and updates the in-memory index. Returns the assigned id.
- `range(store, kind, since_id) -> []Record`: the records of `kind` with
  `id > since_id`, in ascending id order (the half-open `(since_id, ∞)` slice).
- Crash-safe appends: a line is self-contained and flushed, so an interrupted
  write loses at most the trailing line; replay stops at the first
  non-decodable line without aborting.

**Non-Goals:**
- Wiring the store into the daily job or any endpoint — it is a library that
  the orchestration change constructs and drives later.
- Token encode/decode (FR-9) — the store speaks plain ids; the download change
  adds `base64("<kind>:<id>")`.
- EPUB generation, `/download`, and the embedded UI (FR-8, FR-13, US-004,
  US-007) — all later.
- Retention/age-based prune (FR-16) — a separate maintenance change; the
  `intent` frames it as a ceiling-bound follow-up. The store is append-only
  here.
- Concurrency control — in this cut no caller appends or ranges concurrently
  (no scheduler/endpoint is wired). The first change to introduce a concurrent
  caller adds synchronization. Noted as a ceiling (D6).
- Compression, compaction, or a binary format — JSONL text via `std.json`.

## Decisions

### D1. JSONL append log is the single source of truth; ids are log positions
The JSONL file is authoritative. Each record carries its own `id` (a global
monotonic `u64`), and the next-id counter is `max(existing ids) + 1` after
replay — so ids are stable across restarts and never reused. Writing the id
*into* each line (rather than deriving it from the line number) makes replay
robust to a truncated/corrupt trailing line: replay reads valid lines and
ignores the partial last one without miscounting. The file is append-only in
this change; no in-place edits.
- *Alternative:* derive id from line number. Rejected — a half-written trailing
  line would shift every subsequent id on replay, silently breaking token
  range bounds.
- *Alternative:* SQLite (intent §7 ceiling). Rejected for v1 — JSONL via
  `std.json` is zero-dep, append-mostly, and trivially replayable at digest
  volume.

### D2. One self-contained JSON object per line, flushed
Each `append` writes exactly one line terminated by `\n` and flushes the file
before returning, so the bytes reach the OS (and the next open sees them).
A crash mid-write therefore truncates at most the line being written, never a
prior record. Records are serialized with `std.json` (`stringify`), one object
per line; the field set is the curated item fields plus `id` and `kind`.
- *Alternative:* buffer many appends and flush once. Rejected for v1 —
  durability per item beats throughput at digest volume; revisit only if append
  rate is ever a bottleneck.

### D3. Replay rebuilds the index and the next-id counter
On `load`, the store reads the file line by line, decoding each as JSON into a
`Record`. Valid lines extend the per-kind in-memory id lists and the next-id
counter; the first line that fails to decode terminates replay (the line is
treated as a torn tail and ignored — see D2/D5). The in-memory index maps each
kind to the ascending list of its ids; `range` is then an index slice plus
record resolution by id.
- *Alternative:* lazy scan-on-query. Rejected — intent FR-6 specifies an index
  rebuilt on startup, and a warm index makes every range query a slice.

### D4. Records held in memory, indexed by id; per-kind id lists for ranges
The replayed records are held in an `ArrayList(Record)` in id order (which
equals append order, since ids are monotonic), addressable by id (ids are dense
from 1, so record index `id - 1`). Two per-kind `ArrayList(u64)` id lists
support the range query: binary-search `by_kind[kind]` for the first id
`> since_id` and slice to the end, then resolve each id to its record. This is
`O(log n + k)` per range and `O(n)` memory at digest volume.
- *Alternative:* store only ids in memory and re-read bodies from disk per
  range. Rejected — pointless I/O at this volume; the whole log fits trivially.
- `// ponytail: all records in memory + dense id→index; fine at digest volume
  (tens–low hundreds/day, ≤90-day retention). Revisit when the log grows past
  memory comfort; SQLite is the intent §7 ceiling.`

### D5. Torn-tail tolerance: stop at the first undecodable line
Replay decodes lines until EOF or the first line that does not decode as a valid
`Record` (a torn write, a partial flush). That line and anything after it are
ignored for index/counter purposes; a later, complete append overwrites/extends
past it. No repair is performed in this change (no truncation, no rewrite) —
the log stays append-only and the next-id counter is derived only from valid
lines, so a torn tail never lowers an assigned id.
- *Alternative:* truncate the file at the torn line on load. Rejected for now —
  a read opening a shared file should not mutate it; repair belongs with
  retention/compaction (the FR-16 follow-up).

### D6. No synchronization in this cut
The store has no mutex in this change because no concurrent caller exists yet
(neither the daily job nor `/download` is wired here). When the first change
introduces a concurrent writer (the scheduler) alongside concurrent readers
(`/download`), it adds a lock around `append` and the index, or wraps the store
behind a single owner. Documenting this now prevents a false sense of
thread-safety.
- *Alternative:* add a mutex now. Rejected — locks for callers that do not exist
  is speculative scaffolding; add it at the first concurrent caller.
- `// ponytail: single-threaded store until a concurrent caller lands; guard
  append + index with a mutex in the orchestration change.`

## Risks / Trade-offs

- **[Torn trailing line corrupts ids]** → Mitigation: id is stored per-record,
  not derived from position (D1); replay ignores undecodable tails (D5), so a
  torn write never shifts surviving ids or lowers the next-id counter.
- **[Memory growth with retention]** → Mitigation: at digest volume the whole
  log is small (D4); the retention follow-up (FR-16) bounds it. Ponytail
  ceiling noted; SQLite is the documented escalation.
- **[No concurrency yet]** → Mitigation: explicitly out of scope (D6); the
  first concurrent caller adds synchronization. No caller in this cut touches
  the store concurrently.
- **[JSONL parse cost on a large log]** → Mitigation: replay-on-startup is the
  only full read; range queries hit the in-memory index (D3/D4). At digest
  volume startup replay is negligible.
- **[Field-shape churn in the Record]** → Mitigation: `std.json` ignores
  unknown fields on replay and writes only known fields; adding a field is
  additive and does not break older lines (a missing field defaults).

## Migration Plan

Greenfield and additive — no migration. Deploy by: nothing required at startup;
the store file is created lazily at `$XDG_DATA_HOME/curation/items.jsonl` on
the first `append`. No config, store, endpoint, or runtime behavior changes in
this cut (the server keeps serving the placeholder `/`); the store is
exercised only by `zig build test` against temp files. Rollback is
`git revert` (and optionally deleting the unused `items.jsonl`).

## Open Questions

- None blocking. Whether `append` returns the id by value or via an out-param
  is an implementation detail; the spec fixes only that an append assigns and
  yields the next monotonic id. Repair/truncation of a torn tail (D5) and
  retention (FR-16) are deliberate later ceilings.
