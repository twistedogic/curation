## Why

After nine archived changes, `curation` has the full feed→digest pipeline:
server + config (`add-server`), the pure curation pipeline
(`add-curation-pipeline`), feed fetching + parsing (`add-feed-fetching`), the
`pi` longevity evaluator (`add-longevity-evaluator`), the append-only JSONL
store (`add-storage`), the token codec + EPUB builder + `GET /download`
(`add-epub-download`), the embedded download page (`add-download-ui`), the
end-to-end daily job (`add-curation-job`), and web-content rendering via
Lightpanda (`add-web-rendering`). Items are acquired, curated, classified, and
appended to the store — and they stay there forever. Nothing ever removes a
record, so the JSONL log and the in-memory index grow without bound.

That is the gap the intent closes with a numbered Functional Requirement.
`.see/intent.md` **FR-16** states it directly: "items older than a configurable
window (default 90 days) are pruned from the store, regardless of delivery
status," and **Decision #5** fixes the policy: retention is an age-based prune,
default 90 days, because news is ≤3 months by definition and older items are
irrelevant. The store is the right place for it: every prior change has carved
retention *out* on purpose — the `storage` spec's capability boundary says "no
age-based retention," the `download` spec says "no age-based retention," and the
`add-web-rendering` proposal leaves "FR-16 stays a later slice." So today a
90-day-old item is still served on the next `/download` and still occupies the
in-memory index, indefinitely.

This change is that slice: an age-based prune the store performs on its own
records, triggered at the end of each curation run (the run already holds the
store and runs at least daily), sized by a new server-owned `retention_days`
config field (default 90, `0` disables). It deletes only records whose `date`
parses to an instant older than the window; undated records are kept. curation
stays a single binary, stdlib-only, and `zig build test` stays green.

## What Changes

- Add a new **age-based prune operation in the `storage` capability**
  (`src/store.zig`): `Store.pruneByAge(now_epoch_seconds, max_age_seconds)
  -> pruned_count`. It removes every record whose `date` parses (ISO-8601 /
  RFC-3339 or RFC-822) to an instant strictly older than `now - max_age`;
  empty/unparseable `date` records are kept. It rewrites the JSONL log
  atomically (write survivors to a sibling temp file, then replace), rebuilds
  the in-memory `records` list and the per-kind id indexes from the survivors,
  leaves `next_id` unchanged (ids are never reused), holds the store mutex for
  the whole duration, and returns the count removed. It performs no fetching,
  evaluation, serving, scheduling, token, or EPUB work.
- Modify the **`storage` capability boundary** so the store owns age-based
  retention pruning of its own records (it currently forbids it). No other
  deletion path is introduced.
- Modify the **`curation-job` capability** so a run, when given a non-zero
  retention window in days, prunes the store via `pruneByAge` after appending
  survivors (measured against the run's wall-clock time); a window of `0` skips
  the prune. The run summary gains a `pruned` count (zero when disabled or
  nothing was old enough). The `One run at a time` serialization, the
  per-source error isolation, and the summary's existing fields are unchanged.
- Modify the **`curation-job` capability boundary** so the job mutates the
  store through the `storage` capability's append **and** age-based prune
  operations (it currently names only append).
- Modify the **`server` capability's** JSON config schema to add
  `retention_days` (non-negative integer, default `90`, `0` disables pruning).
  The two `tryRun` call sites (the `POST /curate` handler and the daily
  scheduler) pass `cfg.retention_days` to the job. Unknown fields stay ignored,
  so this is additive and non-breaking.
- Standard library only; `zig build test` stays green. No new EPUB kind, no
  provider credentials, no change to any HTTP route or status code, and no
  per-client delivery tracking (Decision #5's ceiling stays a later slice).

## Capabilities

### Modified Capabilities
- `storage`: gains an age-based `pruneByAge` operation that removes records
  older than a window by their parsed `date`, rewrites the JSONL log and
  rebuilds the in-memory index atomically, never reuses ids, and keeps
  undated/unparseable records. Its capability boundary is widened to own
  retention pruning; every other boundary (no serving, scheduling, evaluation,
  token, EPUB, fetching) is unchanged. The append path, the range query, the
  `load` replay, and the mutex contract are unchanged.
- `curation-job`: a run now accepts a retention window in days and, when it is
  non-zero, prunes the store after appending survivors; the run summary gains a
  `pruned` count. Its capability boundary now names prune alongside append as
  the allowed store mutations. The one-at-a-time serialization, the per-source
  error isolation, the acquire/pipeline/classify/append order, and the summary's
  existing fields are unchanged.
- `server`: the JSON config schema it owns gains `retention_days` (default 90,
  0 disables); the two `tryRun` call sites (the `POST /curate` route and the
  daily scheduler) pass the new field to the job. The `/download`, `/curate`,
  `/healthz`, `/metrics`, and `GET /` contracts, the bearer gate, and the
  scheduler timing are unchanged.

## Impact

- **Code:** `src/store.zig` gains `pruneByAge` + a private date parser
  (ISO-8601/RFC-3339 and RFC-822 → epoch seconds, or null) + an atomic
  log-rewrite helper, and self-checks; `src/config.zig` gains a `retention_days:
  u32 = 90` field on `Config` (value type, no allocation, mirrored in the
  `load` literal) and parse/default tests; `src/curation_job.zig` adds a
  `retention_days: u32` parameter to `run`/`tryRun`, a `pruned: usize` field on
  `Summary`, the post-append `pruneByAge` call (guarded by `retention_days > 0`,
  computing `now` from the wall clock), and a self-check; `src/server.zig`
  passes `cfg.retention_days` at the two `tryRun` call sites.
  `fetch.zig`, `feed.zig`, `curation.zig`, `longevity.zig`, `download.zig`,
  `render.zig`, and `ui.zig` are consumed unchanged.
- **APIs:** no HTTP route or status change. `POST /curate` and the daily
  scheduler now also prune after a run, but their request/response contracts
  (bearer gate, `200` + summary / `409` / `401`; scheduler skip-on-busy) are
  unchanged — the summary JSON simply gains a `pruned` key. The `curation-job`
  `run`/`tryRun` signatures widen (one new param); they are internal library
  seams, not an HTTP contract. The `storage` `pruneByAge` signature is a new
  library seam.
- **Dependencies:** none added — Zig 0.16 standard library only (`std.time`,
  `std.json`, `std.Io.Dir` for the atomic rename). Stays a single binary.
- **Data:** the existing JSONL store gains no new fields or format change —
  `pruneByAge` only removes whole lines. Once a run executes with
  `retention_days` configured, records older than the window are deleted from
  the log and disappear from subsequent `/download` ranges (per Decision #5,
  prune is regardless of delivery status). An operator who sets
  `retention_days: 0` gets today's never-prune behavior exactly.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the store
  `pruneByAge` self-check (old record pruned / recent kept / undated kept /
  ISO-8601 and RFC-822 both accepted / ids not reused / log matches survivors /
  mutex-serialized), the config `retention_days` default-and-parse tests, and
  the job pruning-after-run self-check (a run with window 90 prunes a 100-day
  record and reports `pruned`; a window-0 run prunes nothing).
