## 1. Item model

- [x] 1.1 Add `src/item.zig` defining `Item` (title, url, body, date, source)
  and `CuratedItem` (same fields + `tags: []const []const u8`); plain value
  records, no I/O.
- [x] 1.2 Self-check: a `CuratedItem` round-trips its five input fields and
  exposes its tag slice (spec: Curated item model).

## 2. Rule configuration

- [x] 2.1 Define `Rules` (filter include/exclude rules, tag rules, cap) and add
  optional `filter_rules`, `tag_rules`, `cap` fields to `Config` in
  `src/config.zig`, decoded by the existing `std.json` loader (design D6).
- [x] 2.2 Self-check: absent rules default to pass-through; unknown fields
  ignored; `cap: 0` means unbounded (spec: Rule configuration).

## 3. Normalization and dedupe

- [x] 3.1 Implement URL normalization (lowercase scheme/host, drop fragment,
  drop one trailing slash; keep query) and the empty-URL title-hash fallback via
  `std.crypto.hash.sha2.Sha256` (design D2).
- [x] 3.2 Implement first-occurrence-wins dedupe by dedupe key, preserving
  survivor order.
- [x] 3.3 Self-check: case/fragment/trailing-slash collapse to one survivor;
  distinct queries survive; empty-URL same-title collapse (spec: Normalization
  and deduplication).

## 4. Filter rules

- [x] 4.1 Implement case-insensitive substring include/exclude matching on
  title and/or URL (design D3), include gate deny-by-default, exclude drops
  matches, filter before tagging (design D4).
- [x] 4.2 Self-check: exclude drops a match; include is deny-by-default; no
  include rules allows all; matching is case-insensitive (spec: Filter rules).

## 5. Tag rules

- [x] 5.1 Implement tag rules (tag name + target + case-insensitive substring);
  append in first-match order, de-duplicate by exact name; tagging after filter,
  before cap (design D5).
- [x] 5.2 Self-check: a match assigns the tag; repeated matches do not
  duplicate; a filtered-out item is never tagged (spec: Tag rules).

## 6. Pipeline and cap

- [x] 6.1 Implement `curate(allocator, items, rules) -> []CuratedItem` running
  normalize → dedupe → filter → tag → cap in order; pure, no I/O (design D1).
- [x] 6.2 Self-check: same inputs yield identical output across two runs;
  cap truncates to the limit preserving order; unset/zero cap is unbounded;
  an earlier-stage drop preempts a later stage (spec: Deterministic pipeline,
  Per-run cap).

## 7. Integration

- [x] 7.1 Register the new module(s) in `main.zig`'s comptime test import
  block so `zig build test` discovers them.
- [x] 7.2 `zig build test` green.
