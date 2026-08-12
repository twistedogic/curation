## 1. Stamp the acquisition date (sources capability)

- [ ] 1.1 In `src/render.zig`, add a small local helper that formats an epoch-
  seconds value as ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`) from `std.time.epoch`
  — `EpochSeconds` → `getEpochDay().calculateYearDay().calculateMonthDay()` for
  the date and `getDaySeconds()` → hours/minutes/seconds for the time — the exact
  inverse of `storage`'s `parseDateEpoch`. Allocate the result with `gpa` and
  free it in `freeAcquired` (design D4; spec: Web-content acquisition via
  Lightpanda).
- [ ] 1.2 In `acquireWeb`, replace `const date = try gpa.dupe(u8, "");` with the
  helper applied to `std.Io.Clock.now(.awake, io)` — the same clock call
  `server.zig`'s scheduler uses — so every rendered web item carries a non-empty,
  `parseDateEpoch`-parseable ISO-8601 UTC acquisition instant (design D2; spec:
  Web-content acquisition via Lightpanda). No change to the item's `body`, `url`,
  `title`, `source`, the one-item-per-source invariant, or the error contract.
- [ ] 1.3 Leave `acquireWeb`'s signature unchanged (`io` already carries the
  clock); add a `ponytail:` note recording that the web-item date is the capture
  instant (not a parsed publish date — Lightpanda `--dump markdown` carries none,
  FR-4) and that the ISO-8601 helper lifts to a shared util if a second caller
  appears (design D4/D5).

## 2. Retire the deferred-shortcut note (storage capability)

- [ ] 2.1 In `src/store.zig`, rewrite the `pruneByAge` `ponytail:` note (currently
  *"undated records (web items) never prune by date; upgrade when web-item
  retention matters …"*) to record that web-content items now date themselves at
  acquisition, so they prune like feed items; keep the note that genuinely-
  undated records (e.g. a feed item with a missing/malformed `<pubDate>`) are
  still kept by design (design D5). **No behaviour change** to `pruneByAge`,
  `parseDateEpoch`, `append`, `range`, or the record format.

## 3. Tests (sources capability)

- [ ] 3.1 Update the `acquireWeb` success test (`src/render.zig`): replace the
  `expectEqualStrings("", items[0].date)` assertion with one that the rendered
  item's `date` is non-empty, matches the ISO-8601 UTC shape
  (`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`), and **round-trips through
  `storage`'s `parseDateEpoch`** — the same parser `pruneByAge` uses — so a
  malformed stamp fails the build (design D4/D5; spec: Web-content acquisition
  via Lightpanda — "a successful render stamps the acquisition date").
- [ ] 3.2 Add a retention regression: a store holding one record whose `date` is
  an old ISO-8601 UTC instant (a web item's stamped shape) and one recent record,
  called with `pruneByAge(now, window)` that makes the old one old, prunes exactly
  the old record and returns count `1` — the regression that fails the build if
  the empty-date stamp returns (design D1; spec: Age-based retention prune —
  "records older than the window are removed"). Cover via `src/store.zig`'s
  existing prune-test harness or a focused case in `src/render.zig`; the
  `storage` spec's "undated records are kept" scenario is left intact for
  genuinely-undated records.

## 4. Integration

- [ ] 4.1 No new module to register (`render.zig` is already imported in
  `main.zig`'s comptime test block and wired through `curation_job`'s
  `acquireWeb`); no public signature, store-format, JSONL, token, route, EPUB, or
  `/metrics` change. The `download` capability does not render `date` into the
  XHTML, so no generated EPUB changes.
- [ ] 4.2 `zig build test` green; `openspec validate add-web-item-retention`
  passes; `openspec validate --all` stays green (9 capabilities).
