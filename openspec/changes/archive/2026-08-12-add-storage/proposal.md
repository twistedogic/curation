## Why

`curation` can fetch/parse sources, run the pure
normalize/dedupe/filter/tag/cap pipeline, and label each survivor's longevity
through `pi` into a stream `Kind` (archived `add-server`,
`add-curation-pipeline`, `add-feed-fetching`, `add-longevity-evaluator`). But
nothing yet persists the labeled items, and the per-kind watermarks, tokens,
and the two EPUBs (FR-6, FR-8, FR-9, US-004) all need a durable record store
they can query by kind over a monotonic id range. Per intent FR-6 the next
stage is an append-only JavaScript Object Notation Lines (JSONL) item log —
one record per line via `std.json` — with a global monotonic id and a kind, and
an in-memory per-kind index rebuilt on startup so a range query
(`kind = K AND id > since`) is a cheap slice. This is the smallest slice that
makes a labeled item durable and queryable; it is the foundation everything
downstream reads from.

## What Changes

- Add a **durable item store**: an append-only JSONL log at
  `$XDG_DATA_HOME/curation/items.jsonl` (resolving to `~/.local/share/curation/`
  when unset), where each line is one `std.json` record carrying the curated
  item fields plus a **global monotonic id** and the stream **kind** (`news` or
  `knowledge`). The log is the single source of truth.
- Add an **in-memory index rebuilt on startup**: replay the JSONL to restore the
  next-id counter and, for each kind, the sorted list of ids, so a range lookup
  by kind is an index slice, not a full scan.
- Add a **store API**: `load` (open/replay), `append(kind, item) -> id`
  (assigns the next id, writes one line, updates the index), and
  `range(kind, since_id) -> []Record` (the records of that kind with
  `id > since_id`, in id order — exactly the half-open range a download token
  resolves to).
- Make appends **crash-safe**: each record is one self-contained line written
  and flushed so an interrupted write truncates at most the trailing line, and
  replay tolerates a missing/garbled trailing line by stopping there.
- stdlib-only (`std.json`, `std.fs`, `std.io`); no new dependency. Not wired
  into any endpoint or schedule in this change; `zig build test` stays green.

## Capabilities

### New Capabilities
- `storage`: The durable item store — an append-only JSONL log of curated items
  keyed by a global monotonic id and a stream kind (`news`/`knowledge`), plus an
  in-memory per-kind index rebuilt on startup. Owns `append` and a kind+id
  range query. Owns no fetching, curation, longevity evaluation, scheduling,
  HTTP serving, token encoding, EPUB generation, or retention.

### Modified Capabilities
<!-- None. The store is a new, standalone capability. Config loading behavior
(server capability) is unchanged: no new config fields are required to load,
append, or range-query the store in this cut (the data path resolves via XDG),
so no spec-level change to `server`. -->

## Impact

- **Code:** new `src/store.zig` (the `Store` type, JSONL append/replay, the
  per-kind in-memory index, and the `Record` value) plus a small `Store.Record`
  JSON shape. No existing behavior changes; the server still serves the
  placeholder `/` and no store instance is constructed in a request path yet.
- **Data:** introduces a runtime data file `items.jsonl` under the XDG data dir;
  created lazily on first append if absent. Read-only replay on startup; no
  schema migration for a greenfield log.
- **Dependencies:** none added — Zig 0.16 stdlib only (`std.json`, `std.fs`,
  `std.io`). Stays a single binary; the store is a local file, not an external
  database.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the new
  self-checks (append, replay/restore-after-restart, range half-open bounds,
  crash-safe trailing-line tolerance) against temp files.
