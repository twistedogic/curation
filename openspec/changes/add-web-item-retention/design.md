## Context

`curation`'s retention path is built: every curation run appends its survivors
to the append-only JSONL store and then calls the `storage` capability's
`pruneByAge(now_epoch_seconds, max_age_seconds)`, which removes any record whose
`date` parses to an instant older than the window (intent **FR-16**; `curation-job`
spec, *"a run prunes old records when a retention window is set"*). Feed items
date themselves — the `sources` capability extracts `date` from an RSS
`<pubDate>` or an Atom `<updated>`/`<published>` — so they prune normally.

Web-content items do not. The `sources` capability's **Web-content acquisition
via Lightpanda** requirement fixes `body`, `url`, `title`, and `source`, and is
silent on `date`; the renderer stamps every web item empty:

```zig
// src/render.zig, acquireWeb
const date = try gpa.dupe(u8, "");
```

The storage prune then keeps it by spec — *"A record whose `date` is empty or
cannot be parsed … SHALL be kept"* — and its own deferred-shortcut note says
*"undated records (web items) never prune by date; upgrade when web-item
retention matters — … or have `acquireWeb` stamp a date."* The intent is
explicit that web rendering delegates extraction to Lightpanda's `--dump
markdown` *"with no separate readability step"* (**FR-4**), so there is no
publish date to extract — the only honest stamp is the capture instant. The net
effect is that **every web item accumulates forever**: `curation` is a daily
daemon, the store is append-only, and `pruneByAge` rewrites the whole log on
every run, so both the file and the daily rewrite cost grow without bound for any
web source. This is the one record kind that escapes **FR-16**.

This change applies the deferred-shortcut note's own second remedy — *"have
`acquireWeb` stamp a date"* — reusing machinery that already exists rather than
adding any.

## Goals / Non-Goals

**Goals:**
- A web-content item whose captured instant is older than the retention window
  is pruned by the existing `pruneByAge`, identically to a feed item — so
  **FR-16** ("items older than a configurable window are pruned … regardless of
  delivery status") holds for web-content items, and the store and the daily
  rewrite stop growing without bound.
- Zero store-format migration: the item already has a `date` field and
  `pruneByAge` already prunes dated records, so the change is confined to the
  acquisition boundary (`src/render.zig`).
- `openspec validate add-web-item-retention` passes; `openspec validate --all`
  stays green (9 capabilities); `zig build test` stays green.

**Non-Goals:**
- No publish-date extraction from rendered pages. Lightpanda's `--dump markdown`
  is the body with no readability step (**FR-4**); there is no reliable publish
  date to extract, and retention is age against the run clock, not content age.
- No store-format or JSONL record change, no append-time/insertion field, no
  migration of existing empty-dated web records (design D3).
- No change to `pruneByAge`, `parseDateEpoch`, `append`, `range`, the token
  codec, the EPUB builder, `/download`, `/metrics`, or any capability other than
  `sources`. The storage spec's *"undated or unparseable records are kept"*
  scenario is unchanged — it still covers genuinely-undated records (e.g. a feed
  item with a missing/malformed `<pubDate>`).
- No change to `acquireWeb`'s signature, its error contract, or its one-item-
  per-source invariant. Standard library only; single binary; no new dependency.

## Decisions

### D1 — Stamp the date in `acquireWeb`, not via a new store field

The deferred-shortcut note offers two remedies: *"add an append-time field to the
record format (a one-time JSONL migration) and prune by insertion age"* **or**
*"have `acquireWeb` stamp a date."* The item already carries a `date` field, and
`pruneByAge` already prunes dated records, so the second remedy delivers the
retention outcome with **no record-format change, no migration, and no
`storage`-capability change**. The first remedy is strictly more work (a JSONL
schema change + a one-time rewrite of every existing record + a new prune
dimension) for the same result. Lazy fix = stamp the field that already exists.

### D2 — Stamp the acquisition instant, not a content publish date

Retention (**FR-16**) is age measured against the run's wall clock — the
`curation-job` prune scenario measures *"older than the window measured against
the run's wall-clock time,"* and `pruneByAge` takes `now_epoch_seconds` from the
run. A web page's publish date is not available: Lightpanda's `--dump markdown`
is the extracted body with *"no separate readability step"* (**FR-4**), so
nothing parses a publish date. The capture instant (`std.Io.Clock.now(.awake,
io)` at the moment `acquireWeb` finishes rendering) is therefore the honest,
available stamp, and it shares the run-clock reference the prune already uses.
For a web item captured during a run and pruned in a later run, capture time and
run time differ by at most one curation cycle — far below the 90-day window.

### D3 — Format as ISO-8601 UTC; do not migrate existing records

`pruneByAge` parses only ISO-8601 / RFC-3339 / RFC-822 dates; *"any other format
yields an unparseable (kept) record."* So the stamp must be one of those, and
ISO-8601 UTC (`2026-08-13T04:00:00Z`) is the form `parseDateEpoch` already
accepts and that the storage spec's own examples use. Existing on-disk web
records written before this change keep their empty `date` and, per the
unchanged storage spec, remain kept until they would age out — but they never
age out. Migrating them (backfilling a capture instant) is impossible: the
capture instant was never recorded, and inventing one would be a lie. Leaving
them is correct and bounded: they are a fixed, finite cohort (only web items
written before deploy), they stop accumulating the moment this change ships, and
an operator who wants them gone can drop the store once (ids are never reused, so
no downstream token is invalidated beyond a one-time re-download). No migration
code, no schema version.

### D4 — Build the ISO-8601 string from `std.time.epoch` (the inverse of `parseDateEpoch`)

`acquireWeb` already receives `io`, and `std.Io.Clock.now(.awake, io)` returns
the instant (`server.zig`'s scheduler uses the identical call). `std.time.epoch`
turns epoch seconds into calendar parts (`EpochSeconds` → `getEpochDay()` →
`calculateYearDay()` → `calculateMonthDay()` for year/month/day;
`getDaySeconds()` → `getHoursIntoDay()` / `getMinutesIntoHour()` /
`getSecondsIntoMinute()` for the time) — the exact inverse of `storage`'s
`parseDateEpoch`. No libc, no new dependency, no `@cImport`. The helper is a
small local function in `src/render.zig` (mirroring `parseDateEpoch` in reverse);
it lifts to a shared util only if a second caller appears. (A stdlib
ISO-8601 calendar formatter was checked for and is absent in 0.16; `std.time.epoch`
is the stdlib path.)

### D5 — Retire the deferred-shortcut note; keep the storage spec as-is

Once web items date themselves, the `pruneByAge` `ponytail:` note in
`src/store.zig` — which exists solely to track this gap — is resolved for the
systemic web-item case and is rewritten to say so. The `storage` spec needs no
change: its prune requirement already removes dated records, and its *"undated or
unparseable records are kept"* scenario still holds for genuinely-undated records
(a feed item whose `<pubDate>` is missing/malformed). The regression that matters
lives in `sources`: a rendered item carries a `parseDateEpoch`-parseable date,
and a store holding an old web-dated record is pruned.

`// ponytail: web item date = capture instant (std.Io.Clock + std.time.epoch),
// not a parsed publish date (Lightpanda --dump markdown carries none, FR-4);
// retention is age against the run clock (FR-16). Lift the ISO-8601 helper to a
// shared util if a second caller appears.`

## Risks / Trade-offs

- **Capture time ≠ publish time for web items, so a web item's `date` is not its
  content date.** → Mitigation: this is honest (no publish date is available),
  retention is age-against-run-clock not content-age, and the field is not
  rendered into the EPUB (`download` uses `date` only in fixtures and ZIP
  metadata), so no reader-facing output changes. Feed items keep their publish
  dates; only web items differ, and only in the store's retention behaviour —
  which is the bug being fixed.
- **Existing empty-dated web records are not migrated and never prune.** →
  Mitigation (design D3): they are a finite pre-deploy cohort that stops growing
  on ship; backfilling a capture instant is impossible (it was never recorded);
  an operator can drop the store once if desired, with no lasting token
  corruption (ids are never reused). The cost of the status quo is unbounded
  growth; the cost of this approach is one bounded cohort.
- **A clock that jumps backward (NTP step) could stamp a web item slightly before
  a prior one.** → Mitigation: `pruneByAge` is age-based on each record's own
  date against the run `now`, not on inter-record ordering, and store ids remain
  strictly monotonic regardless of date, so a backward clock step affects only
  the pruning window of the affected item by the step size — negligible against
  90 days and non-fatal (worst case: one item is kept one extra cycle).
- **New helper could format an invalid date string.** → Mitigation: the regression
  asserts the rendered `date` round-trips through `storage`'s `parseDateEpoch`
  (the same parser `pruneByAge` uses), so a malformed stamp fails the build, not
  the run.
