## 1. Embedded page asset and `ui` module

- [ ] 1.1 Add `src/ui.html`: a single static HTML document with inlined
  `<style>` and `<script>`, no JS framework, no build step, no external asset
  requests. It renders exactly two download affordances (`news`, `knowledge`)
  and the bearer-token entry; holds `curation.token.news`,
  `curation.token.knowledge`, and `curation.bearer` in `localStorage`
  (design D2; spec: Embedded single-page download UI, Per-kind download
  affordances and client token state, Bearer token entry).
- [ ] 1.2 Implement the page's client contract in the inlined `<script>`: each
  affordance sends `Authorization: Bearer <curation.bearer>` and its kind's
  stored token as `since` to same-origin `GET /download`; on `200` triggers the
  body as a Blob download and stores `X-Next-Token` for that kind; on `204`
  shows "nothing new" and leaves the token unchanged; on `401` re-prompts for the
  bearer; only `X-Next-Token` ever writes a token (design D4; spec: Per-kind
  download response handling).
- [ ] 1.3 Implement the first-download bootstrap in the inlined `<script>`: when
  a kind has no stored token, request `GET /download?kind=<kind>` (no `since`)
  with the bearer; never synthesize a token locally (design D3; spec:
  First-download bootstrap per kind).
- [ ] 1.4 Add `src/ui.zig` exposing `pub const page: []const u8 =
  @embedFile("ui.html");` and a content self-check asserting the page is
  self-contained (no `<script src=`, no `<link rel="stylesheet" href=`, no `://`
  attribute) and renders exactly two per-kind affordances (design D2; spec:
  Embedded single-page download UI).

## 2. `GET /` serves the embedded page (server)

- [ ] 2.1 In `src/server.zig`, replace the `GET /` placeholder branch with a
  response serving `ui.page` verbatim, `Content-Type: text/html; charset=utf-8`,
  status `200`, `open_route = true` (design D1; spec: Embedded download UI
  endpoint).
- [ ] 2.2 Self-check (route handler): `handleRequest` for `GET /` returns `200`,
  `text/html; charset=utf-8`, a body equal to `ui.page`, and `open_route = true`
  with no `Authorization` required (spec: Embedded download UI endpoint).

## 3. First-download bootstrap on `GET /download` (server)

- [ ] 3.1 In `src/server.zig` `handleDownload`, after the auth check (still
  `401` before any resolution): when `since` is present, behave exactly as today
  (decode; empty/malformed → `400`; `kind` ignored); when `since` is absent,
  require `kind` — absent or not `news`/`knowledge` → `400`; otherwise resolve as
  token `{ kind, id = 0 }` via the unchanged `download.resolve` (design D3; spec:
  Download endpoint).
- [ ] 3.2 Self-check (route handler): absent `since` + `kind=news` over news ids
  `[1,3,5]` → `200` EPUB of all three + `X-Next-Token` decoding to `{news,5}`;
  absent `since` + `kind=knowledge` over an empty kind → `204` + no token;
  absent `since` + no `kind` → `400`; absent `since` + `kind=sports` → `400`;
  `since=<garbage>` → `400`;
  `since=<{knowledge,2}>&kind=news` → resolves `knowledge` (param ignored);
  missing/wrong bearer → `401` before any resolution (spec: Download endpoint).

## 4. Integration

- [ ] 4.1 Register `src/ui.zig` in `main.zig`'s comptime test import block so
  `zig build test` discovers it.
- [ ] 4.2 `zig build test` green.
