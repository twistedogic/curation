## Why

Intent **FR-16** requires that *"items older than a configurable window
(default 90 days) are pruned from the store, regardless of delivery status."*
The `storage` capability honours this for any record whose `date` parses: its
**Age-based retention prune** requirement removes *"every record whose `date`
field, when parsed as an ISO-8601 / RFC-3339 date-time or an RFC-822 date-time,
denotes an instant strictly older than `now_epoch_seconds - max_age_seconds`."*

Web-content items never satisfy that clause. The `sources` capability's
**Web-content acquisition via Lightpanda** requirement fixes the item `body`,
`url`, `title`, and `source` but is silent on `date`, and the renderer stamps
every web item with an empty date:

```zig
// src/render.zig, inside acquireWeb
const date = try gpa.dupe(u8, "");
```

The storage prune then **keeps** it by spec — *"A record whose `date` is empty
or cannot be parsed … SHALL be kept (it SHALL NOT be pruned)"* — and its own
deferred-shortcut note says so plainly:

```zig
// src/store.zig, pruneByAge doc comment
// ponytail: undated records (web items) never prune by date; upgrade
// when web-item retention matters — add an append-time field to the
// record format … or have `acquireWeb` stamp a date.
```

So **every web-content item accumulates in the append-only JSONL store forever.**
`curation` is a long-running daily daemon: a single web source fed daily grows
the store without bound, and because `pruneByAge` rewrites the *entire* log
atomically on every run, the daily rewrite cost grows with that accumulation
too. Feed items date themselves from `<pubDate>`/`<updated>` and prune normally;
web items — rendered by Lightpanda's `--dump markdown`, which the intent
(**FR-4**) explicitly assigns as the body *"with no separate readability step"*
and therefore carries no publish date — are the one record kind that escapes
**FR-16** entirely. The deferred-shortcut note names the exact fix this change
applies: *"have `acquireWeb` stamp a date."*

## What Changes

- **Stamp the acquisition instant as the web item's `date`.** In `acquireWeb`
  (`src/render.zig`), replace the empty-string `date` with the renderer's
  wall-clock time at capture, formatted as ISO-8601 Coordinated Universal Time
  (UTC) (e.g. `2026-08-13T04:00:00Z`). The instant comes from the `io` argument
  `acquireWeb` already receives (`std.Io.Clock.now(.awake, io)`, the same call
  `server.zig`'s scheduler already uses); the ISO-8601 string is built from
  `std.time.epoch` — the exact inverse of `storage`'s `parseDateEpoch` — so the
  storage prune parses it with **no parser change**. Acquisition time is the
  honest stamp: Lightpanda's markdown dump carries no reliable publish date, and
  retention (**FR-16**) is age measured against the run's wall clock (design D2).
- **Reuse, do not migrate.** The item already carries a `date` field and
  `pruneByAge` already prunes dated records, so this change touches only the
  acquisition boundary. There is **no JSONL record-format change, no store
  migration, no new store field**, and **no change to `pruneByAge`**: a web item
  with a real date flows through the existing prune path identically to a feed
  item (design D1). The `storage` spec is unchanged.
- **Retire the deferred-shortcut note.** Once web items carry a date, the
  `pruneByAge` `ponytail:` note in `src/store.zig` (which exists *only* to track
  this gap) is resolved for the systemic web-item case and is rewritten to record
  that. Genuinely-undated records (e.g. a feed item whose `<pubDate>` is missing
  or malformed) remain kept by design — the storage spec's *"undated or
  unparseable records are kept"* scenario is unchanged.
- **Add a regression test.** `acquireWeb`'s stub-subprocess test (the proven
  `render.zig` hermetic pattern) is updated to assert the rendered item carries a
  **non-empty, ISO-8601 date that `parseDateEpoch` accepts**; a second check
  asserts a store holding a web-dated record older than the window **is** pruned
  by `pruneByAge` — the regression that fails the build if the empty-date stamp
  returns. Standard library only; `zig build test` stays green. Single binary, no
  new dependency, no store/config/route/token/EPUB change.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `sources`: the **Web-content acquisition via Lightpanda** requirement gains an
  explicit clause that the item `date` SHALL be the acquisition instant formatted
  as ISO-8601 UTC, plus a scenario asserting a successful render stamps that
  date. The `body`/`url`/`title`/`source` contracts, the one-item-per-source
  invariant, the error contract (missing binary / non-zero exit / timeout / empty
  output), and the "no HTTP, no feed parsing" boundary are unchanged. The date is
  not extracted from the rendered page (Lightpanda's `--dump markdown` is the
  body, per **FR-4**); it is the capture instant.

## Impact

- **Code:** `src/render.zig` — `acquireWeb` stamps the `date` from
  `std.Io.Clock.now(.awake, io)` via a small local ISO-8601-UTC formatter built
  on `std.time.epoch` (the inverse of `storage`'s `parseDateEpoch`; lifts to a
  shared util only if a second caller appears). `src/store.zig` — the
  `pruneByAge` `ponytail:` note is rewritten to record that web items now date
  themselves; **no behaviour change** to `pruneByAge`, `parseDateEpoch`,
  `append`, `range`, or the record format. No other `.zig` file changes.
- **Tests:** `src/render.zig` — the `acquireWeb` success test's
  `expectEqualStrings("", items[0].date)` assertion becomes a non-empty
  ISO-8601 + `parseDateEpoch`-parseable assertion; a new case asserts an
  old web-dated record is pruned. `src/store.zig` — no change (its prune tests
  already cover dated records; the "undated records are kept" scenario still
  holds for genuinely-undated records).
- **APIs:** none. `acquireWeb`'s signature (`gpa, io, source_url, source_name,
  lightpanda, timeout`) is unchanged — `io` already carries the clock. The
  `Item` model, the `storage` `Record` format, the token codec, and the
  `/download` and `/metrics` surfaces are unchanged. A web item now carries a
  real date; `pruneByAge` prunes it like a feed item — strictly the behaviour
  **FR-16** already requires.
- **EPUB output:** none. The `download` capability does not render `date` into
  the content/navigation XHTML (it is used only in test fixtures and as ZIP
  metadata), so stamping the field changes no generated EPUB.
- **Dependencies:** none added — Zig 0.16 standard library only (`std.time.epoch`,
  `std.Io.Clock`). Single binary; no external runtime dependency; no libc link.
- **Data:** no store, JSONL, cache-file, token, or record-format change. A
  web-content record's `date` field changes from `""` to an ISO-8601 UTC
  acquisition instant; existing on-disk web records written before this change
  remain empty-dated and (per the unchanged storage spec) are kept until they age
  out — they are not migrated, and migration is not needed (design D3).
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the updated
  date assertion and the new prune regression.
