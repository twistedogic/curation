## 1. Token codec

- [x] 1.1 Add `src/download.zig` with `encode(kind, id) -> []u8` producing
  standard base64 of `"<kind>:<id>"`, and `decode(token) -> { kind, id }` that
  errors on malformed input, an unknown kind, or a non-numeric id (design D2;
  spec: Kind-scoped download tokens).
- [x] 1.2 Self-check: `encode(.news, 7)` round-trips through `decode`; a
  non-base64 string, an unknown kind (`sports:3`), and a non-numeric id each
  error; `encode(.news, 1)` ≠ `encode(.knowledge, 1)` (spec: Kind-scoped
  download tokens).

## 2. EPUB builder (standard library only)

- [x] 2.1 Implement a minimal ZIP writer composing `std.zip`'s
  `LocalFileHeader`/`CentralDirectoryFileHeader`/`EndRecord` structs and
  signatures, with `CompressionMethod.store` for `mimetype` and
  `std.compress.flate.Compress` (DEFLATE) for content bodies (design D3).
- [x] 2.2 Implement `build(gpa, kind, records) -> []u8` emitting `mimetype`
  (stored, first), `META-INF/container.xml`, an OPF package + manifest, an EPUB 3
  navigation document, and one XHTML content document per record (title + body)
  (design D3; spec: Per-kind EPUB generation).
- [x] 2.3 Self-check: building with kind `news` and two records yields a ZIP
  whose first entry is `mimetype` stored as `application/epub+zip`, with one
  XHTML document per record; the same builder also builds a `knowledge` EPUB; the
  build performs no I/O; `build.zig.zon` declares no new dependency (spec:
  Per-kind EPUB generation).

## 3. EPUB structural validity

- [x] 3.1 Add a structural self-check in `src/download.zig` (run by
  `zig build test`) asserting, on a generated EPUB: `mimetype` is first + `store`
  (0) + exact content; `META-INF/container.xml` names an OPF that exists; the OPF
  manifest references the navigation document and exactly N XHTML documents, all
  present in the container (design D6; spec: EPUB structural validity).
- [x] 3.2 Self-check fails the build if any condition is violated (spec: EPUB
  structural validity).

## 4. Incremental resolver

- [x] 4.1 Implement
  `resolve(gpa, store, token) -> { epub, next_token } | nothing_new` that ranges
  the store by `kind = token.kind AND id > token.id`, signals nothing-new on an
  empty range, and otherwise builds the EPUB and returns
  `encode(kind, last_included.id)` as the next token (design D5; spec:
  Incremental download resolution).
- [x] 4.2 Self-check: token `{news,1}` over news ids `[1,3,5]` yields ids 3,5
  and next `{news,5}`; `{news,5}` over a largest id of 5 signals nothing-new;
  `{news,0}` yields all three news records; a `news` token never returns a
  knowledge record (spec: Incremental download resolution).

## 5. `/download` route (server)

- [x] 5.1 Add the `GET /download?since=<token>` route to `src/server.zig`,
  bearer-gated via the existing auth check: valid token + nothing-new →
  `204 No Content`; valid token + EPUB → `200` with
  `Content-Type: application/epub+zip` and `X-Next-Token`; absent/malformed
  `since` → `400` (design D4/D5; spec: Download endpoint).
- [x] 5.2 Self-check (route handler): valid `{news,1}` + items → `200` EPUB +
  `X-Next-Token` decoding to `{news,5}`; nothing-new → `204` + no token; absent
  `since` and a `garbage` `since` → `400`; missing/wrong bearer → `401` (spec:
  Download endpoint).

## 6. Integration

- [x] 6.1 Register `src/download.zig` in `main.zig`'s comptime test import
  block so `zig build test` discovers it.
- [x] 6.2 `zig build test` green.
