## Why

`curation` can fetch/parse sources, run the pure normalize/dedupe/filter/tag/cap
pipeline, label each survivor's longevity into a stream `Kind`, and persist
labeled records with global monotonic ids and a per-kind range query (archived
`add-server`, `add-curation-pipeline`, `add-feed-fetching`,
`add-longevity-evaluator`, `add-storage`). But nothing yet delivers items to a
client. The product's defining contract — intent US-004 / FR-8 / FR-9 / FR-10 —
is the incremental, per-kind Electronic Publication (EPUB) download: given a
kind-scoped last-download token, return an EPUB of that kind's items from the
token up to today, plus a token for next time, so a re-download yields only the
delta (never a duplicate, never a gap, never a cross-kind item). The store's
range query and the server's bearer gate already exist; the missing piece is the
token codec, the EPUB builder, and the `/download` route that binds them. This is
the smallest slice that makes a curated item downloadable.

## What Changes

- Add a **kind-scoped token codec**: encode/decode
  `base64("<kind>:<global_id>")` (intent FR-9, Decision #2). Tokens are opaque
  to the client, monotonic, server-issued, and kind-scoped; a malformed or
  unknown-kind token fails to decode. The store speaks plain ids; only this
  codec knows the token wire format.
- Add a **kind-parametric EPUB builder**: a pure function of a `Kind` and its
  ordered records that emits a valid EPUB in memory — `mimetype` stored
  uncompressed and first, `META-INF/container.xml`, an Open Packaging Format
  (OPF) package + manifest, an EPUB 3 navigation document, and one Extensible
  Hypertext Markup Language (XHTML) document per item — using the standard
  library only (`std.zip` header/signature/compression-method definitions plus
  `std.compress.flate` for DEFLATE). No new dependency; single binary preserved.
- Add an **incremental download resolver**: given a decoded token and a store,
  range the store for `kind = token.kind AND id > token.id`; when empty, signal
  "nothing new"; otherwise build the EPUB of those records and yield the next
  token (`encode(kind, last included id)`).
- Add a **`GET /download?since=<token>`** protected route to the server:
  bearer-authenticated (attaching to the existing gate), it resolves via the new
  codec + resolver; on success it streams `200` with
  `Content-Type: application/epub+zip` and an `X-Next-Token` header; with nothing
  new for the kind it returns `204 No Content` and leaves the client's token
  unchanged; an absent or malformed `since` returns `400`.
- Standard library only; `zig build test` stays green. No daily scheduler, web
  UI, or retention in this change — those are later slices that drive this
  endpoint.

## Capabilities

### New Capabilities
- `download`: The pure incremental-delivery engine — a kind-scoped download-token
  codec, a kind-parametric EPUB builder (standard library only), and a resolver
  that turns a token + the storage range query into either an EPUB of the delta
  or a "nothing new" signal. Owns no HTTP serving, fetching, scheduling, storage,
  or longevity evaluation.

### Modified Capabilities
- `server`: gains a `GET /download?since=<token>` protected route that attaches
  to the existing bearer gate and delegates to the `download` capability,
  returning the EPUB (`200` + `X-Next-Token`), `204 No Content` when there is
  nothing new for the kind, or `400` for an absent/malformed token.

## Impact

- **Code:** new `src/download.zig` (the token codec, the EPUB builder, and the
  resolver, all pure and unit-tested without HyperText Transfer Protocol (HTTP));
  `src/server.zig` gains the `/download` route branch and the `X-Next-Token`
  response header; `src/main.zig` registers the new module in its comptime test
  import block. The existing store range query and bearer gate are consumed
  unchanged.
- **APIs:** one new HTTP endpoint, `GET /download?since=<token>` (protected). No
  change to `/`, `/healthz`, or `/metrics`.
- **Dependencies:** none added — Zig 0.16 standard library only (`std.zip`,
  `std.compress.flate`, `std.base64`, `std.json`). Stays a single binary. Note:
  `std.zip` in this toolchain exposes the ZIP container's header structs,
  signatures, and `CompressionMethod` (`store`/`deflate`) but no high-level
  writer, so the builder composes a minimal writer from those primitives plus
  `std.compress.flate` (see design).
- **Data:** no new persistent files; EPUBs are generated on demand in memory and
  streamed. Tokens are stateless encodings of store ids, not stored server-side.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the token
  round-trip, the EPUB structural self-check, the resolver's
  delta/empty/next-token behavior, and the `/download` route's 200/204/400
  paths.
