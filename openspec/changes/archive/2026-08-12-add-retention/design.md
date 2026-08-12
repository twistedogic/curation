## Context

`curation`'s nine archived changes build a complete acquire → curate →
classify → store → serve pipeline. The `storage` capability
(`add-storage`) is an append-only JSONL log with a global monotonic id and an
in-memory per-kind index rebuilt on startup; the `curation-job` capability
(`add-curation-job`, extended by `add-web-rendering`) runs the pipeline
end-to-end and appends survivors; the `server` capability (`add-server`) owns
config, the bearer gate, the routes, and the daily scheduler. Every record ever
appended stays in the store for the life of the process and on disk forever.

The intent calls for bounded retention as a numbered requirement. `.see/intent.md`
**FR-16**: "items older than a configurable window (default 90 days) are pruned
from the store, regardless of delivery status." **Decision #5** fixes the
policy: age-based prune, default 90 days, because news is ≤3 months by
definition; prune regardless of delivery status; revisit per-client delivery
tracking only if multiple clients with divergent watermarks appear. The intent
also marks the simplification with `// ponytail: global age-based prune,
single-user/single-client`.

Every prior change deferred this on purpose. The `storage` capability boundary
says "no age-based retention" and has a scenario "the store owns no retention";
the `download` spec says "no age-based retention"; `add-web-rendering`'s
proposal says "FR-16 stays a later slice." So the deferral is deliberate and
documented, and the store's `Record` model is the only age signal available:
each record carries the item's `date` string (feed items: RFC-822 or
RFC-3339/ISO-8601; web items rendered via Lightpanda: empty). There is no
append timestamp on a record — adding one would be a format migration, which is
out of scope for this slice.

This change adds the prune and wires it in, along the path the existing
capabilities already chose: prune is a store operation (it rewrites the store's
own log and index), it is triggered by the run (which already holds the store
and runs at least daily via the scheduler and on-demand via `POST /curate`),
and its window comes from the server-owned config like every other tunable. It
depends only on already-built, unchanged capabilities: the prune reads the same
`Record` values the range query returns and rewrites the same JSONL file the
`load` replay reads.

## Goals / Non-Goals

**Goals:**
- A library-callable `storage`-capability `pruneByAge(now, max_age_seconds)`
  that removes records whose parsed `date` is older than the cutoff, rewrites
  the JSONL log and the in-memory index atomically, never reuses ids, keeps
  undated/unparseable records, and is serialized with appends and range reads.
- A `curation-job` run that prunes the store after appending survivors when a
  non-zero retention window is configured (and skips prune when it is `0`), and
  reports the pruned count in the summary.
- A `server`-owned `retention_days` config field (default `90`, `0` disables),
  passed to both `tryRun` call sites.
- Self-checks under `zig build test` for the prune, the config field, and the
  job's prune-after-run; `openspec validate add-retention` passes.

**Non-Goals:**
- No per-client delivery tracking. Prune is "regardless of delivery status"
  (Decision #5): a record older than the window is removed even if a slow
  client never downloaded it. Per-client watermarks are a later slice.
- No append-timestamp / record-format migration. Age is measured solely from
  the item's existing `date` field. Consequently undated records (web items)
  are never pruned by this slice — see D2.
- No new HTTP route or status code; no EPUB, token, or longevity change; no
  new dependency; no change to the one-run-at-a-time serialization.
- No scheduled prune independent of the curation run cadence — prune rides the
  daily run (see D4).

## Decisions

### D1 — Prune is a `storage` operation, not a new capability

`pruneByAge` rewrites the store's own JSONL log and rebuilds its own in-memory
index — it is the inverse of `append` and touches the same internals `load`
touches. A separate `retention` capability would be a one-implementation wrapper
that delegates every real action to `storage` and `server`; that is exactly the
unrequested abstraction to avoid. The store's capability boundary is widened to
own retention pruning of its own records, and no other deletion path is added.

### D2 — Age comes from the record `date`; undated records are kept

The only age signal on a `Record` is its `date` string. A private parser in
`store.zig` accepts ISO-8601 / RFC-3339 (`2024-01-01T00:00:00Z`, used by Atom
and Lightpanda) and RFC-822 (`Mon, 01 Jan 2024 00:00:00 GMT`, used by RSS). A
record is pruned iff its `date` parses to an instant strictly older than
`now - max_age_seconds`. An empty or unparseable `date` is **kept** — deleting
what we cannot date is riskier than keeping it, and the store has no append
timestamp to fall back on. This means web-rendered items (`date = ""`) never
age out under this slice.

`// ponytail: undated records (web items) never prune by date; upgrade when
web-item retention matters — add an append-time field to the record format (a
one-time JSONL migration) and prune by insertion age, or have acquireWeb stamp a
date.`

### D3 — Atomic log rewrite; ids never reused

Prune writes the surviving records to a sibling temp file in the same directory
and atomically replaces the store file, then rebuilds `records` and the
per-kind id indexes from the survivors. `next_id` is **never decremented**:
global monotonic ids keep growing, so a pruned id is never handed out again and
existing client tokens (which carry a `global_id`) never collide with a newer
item. This preserves the `/download` range invariant (`id > token.id`) even
across prunes.

### D4 — Prune rides the curation run, not a separate timer

The run already holds the `*Store`, already runs at least once a day via the
scheduler, and is the single mutation point the server drives via `tryRun`
(both `POST /curate` and the daily scheduler route through it). Triggering prune
at the end of a successful run (after appending survivors, guarded by
`retention_days > 0`) reuses that path and adds no thread, clock, or second
store-access channel. Prune is idempotent, so on-demand `POST /curate` runs
pruning extra is harmless. A run whose source list is empty still prunes (it
appends nothing, then prunes), so retention keeps working on quiet days.

`// ponytail: prune cadence is tied to the run cadence (≥ daily); add a
dedicated scheduler tick if retention must run on a different schedule than
curation.`

### D5 — `retention_days` in server-owned config, `0` disables

The server capability owns config; `retention_days: u32 = 90` is a value type
(no allocation), added to the `Config` literal in `load` like `cap`. `0` means
"disabled" — the run skips the prune call entirely — so an operator can opt out
and recover today's never-prune behavior. The window is converted to seconds
(`retention_days * 86400`) at the call site. Default `90` matches Decision #5
and FR-16.

### D6 — The run computes `now`; `pruneByAge` takes it as a parameter

`pruneByAge(now_epoch_seconds, max_age_seconds)` takes the current time as a
parameter so the store self-check is fully deterministic (it injects a fixed
`now`). The run reads the wall clock once (`std.time`) and passes that `now`
plus the seconds window. The job self-check therefore uses dates that are
unambiguously old (e.g. year 2000) versus dates it stamps from the same
`std.time` source the run uses, so it stays hermetic without injecting a clock
into the job signature.

## Risks / Trade-offs

- **Pruning an undelivered item creates a delivery gap.** A record older than
  the window is removed even if a client never downloaded it (Decision #5:
  "regardless of delivery status"). This is the accepted, documented trade-off —
  "older items are irrelevant" — and is operator-tunable (`retention_days`,
  including `0`). The ceiling is per-client delivery tracking (a later slice).
- **Undated records never prune.** Web items carry `date = ""`, so they are kept
  indefinitely under D2. Flagged with a `ponytail:` ceiling and an upgrade path
  (D2). Not a correctness issue, only an unbounded-growth issue for web-only
  deployments.
- **Full-file rewrite on every prune.** `pruneByAge` rewrites the whole JSONL
  log (O(n) in records), holding the store mutex. At digest volume this is
  trivial and runs at most once per curation run. The intent §7 ceiling (move to
  SQLite) covers the case where retention/scan cost or the rewrite becomes
  costly; flagged `ponytail:`.
- **Concurrency.** Prune holds the same mutex `append` and `range` use, so a
  `/download` range read or an `append` briefly waits during a prune. No torn
  reads/writes; bounded by digest volume.
