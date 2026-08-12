## Context

`curation` has, after five archived changes, every ingredient except delivery:
the server bedrock (config, lifecycle, `/healthz`, the bearer auth gate,
structured logging, `/metrics`), the pure curation pipeline ending at cap, feed
fetching + parsing, the `pi` longevity evaluator mapping each survivor to a
stream `Kind` (`news`/`knowledge`), and an append-only JSONL store with global
monotonic ids and a `range(kind, since_id) -> []Record` half-open query. The
server spec explicitly defers `/download`: "later changes attach the download
and write endpoints to [the auth gate]," and the store spec's capability
boundary explicitly excludes "token encoding or decoding [and] EPUB
generation." So the download path is an unbuilt, unowned seam between two
finished capabilities.

`.see/intent.md` fixes the contract precisely. US-004: a client sends a
kind-scoped last-download token and receives the matching EPUB — news or
knowledge — of everything of that kind curated since, plus a token for next
time; with nothing new, `204 No Content` and the same token; exactly two kinds.
FR-8: a kind-parametric EPUB builder renders a kind's range `(token, today]`
into a valid `.epub` in memory, streamed as the body; the same code builds both
EPUBs. FR-9: a token is `base64("<kind>:<global_id>")`, opaque, monotonic,
server-issued, kind-scoped; `<global_id>` is the JSONL log position of the last
delivered item of that kind; the range is `kind = token.kind AND id > token.id`;
two independent watermarks; the server is the sole authority over issuance.
FR-10: `GET /download?since=<token>` → EPUB or `204` (bearer-auth),
`Content-Type: application/epub+zip`, `X-Next-Token` reflecting the last item
included. Decision #2 fixes the token format; §7 fixes EPUB validity
requirements (mimetype stored uncompressed and first, container.xml, OPF
manifest, navigation).

This change builds exactly that: the token codec, the EPUB builder, the
resolver, and the `/download` route. It depends only on the store's `range` and
the server's auth gate, both unchanged. It is deliberately the pure-delivery
slice: the daily scheduler/job (US-002), the embedded UI (US-007), and
age-based retention (FR-16) are all later changes that drive or are driven by
this endpoint.

## Goals / Non-Goals

**Goals:**
- A pure `download` capability, invokable as a library, with no HTTP inside it.
- Token codec: `encode(kind, id) -> []u8` = standard base64 of `"<kind>:<id>"`;
  `decode([]const u8) -> { kind, id }` that fails on malformed input or an
  unknown kind. Tokens for `id >= 1` are the only ones the server issues
  (advance tokens); `id` is the global monotonic store id.
- EPUB builder: `build(gpa, kind, records) -> []u8` producing a valid EPUB in
  memory from a `Kind` and its records in ascending id order.
- Resolver: `resolve(gpa, store, token) -> { epub_bytes, next_token } |
  nothing_new`, ranging the store by `kind = token.kind AND id > token.id`;
  `next_token` encodes the last included record's id; an empty range signals
  nothing-new (the caller keeps its token).
- A `/download` route on the server: bearer-gated, `200 application/epub+zip` +
  `X-Next-Token`, or `204 No Content`, or `400` for an absent/malformed token.
- A structural self-check in `zig build test` asserting the generated EPUB's
  shape (mimetype first + stored, container.xml present, OPF references every
  content doc, nav present).

**Non-Goals:**
- The daily scheduler and the fetch→curate→longevity→store job (US-002) — a
  later orchestration change. This change assumes records already exist in the
  store.
- The embedded web UI (US-007) — a later change. In particular, the
  **first-download bootstrap** (a client with no token yet) is not solved here:
  this change requires a valid `since` token and returns `400` when one is
  absent or malformed (see D4). The UI change owns the bootstrap user
  experience.
- Age-based retention / prune (FR-16) — a separate maintenance change.
- Token persistence server-side — tokens are stateless encodings of store ids;
  the client holds the watermark. No server-side token store.
- Concurrency control on `/download` — readers are stateless range queries over
  the store's in-memory index; the first change to introduce a concurrent
  *writer* (the scheduler) alongside these readers adds store synchronization
  (per the `add-storage` D6 ceiling). No lock is added speculatively here.
- A general ZIP/EPUB library — the builder emits exactly the EPUB structure this
  product needs.

## Decisions

### D1. The `download` capability is a pure engine; `/download` lives in `server`
The token codec, the EPUB builder, and the resolver carry no I/O, no HTTP, and
no scheduling — they are pure functions of (token, store, records), exactly
matching how `curation`, `longevity`, and `store` already separate pure logic
from the HTTP surface in `server.zig`. The `/download` route is HTTP routing +
auth + response shaping, which is the server's job; the server spec already says
the download endpoint attaches to its auth gate. So `download` is a new pure
capability and `server` gains the `/download` endpoint requirement. This keeps
the HTTP surface in one module and makes the engine unit-testable without a
server.
- *Alternative:* put `/download` inside the `download` capability. Rejected — it
  would split the HTTP surface across two capabilities and duplicate the
  auth/routing/metrics plumbing the server already owns.

### D2. Token = standard base64 of `"<kind>:<id>"`; the codec is the only owner of the wire format
`encode(kind, id)` produces `std.base64.standard.Encoder` output of the ASCII
bytes `"<kind>:<id>"` (e.g. `news:7`). `decode` reverses it: base64-decode,
split on the single `:`, map the left side to `Kind` (`news`/`knowledge`),
parse the right side as a decimal `u64`. Any failure (non-base64, no `:`,
unknown kind, non-numeric id) is an error; the caller (the server) turns it into
`400`. The store and the rest of the system speak plain `Kind` + `u64`; only
this codec knows the token format, so a future format change is localized. This
matches intent Decision #2 exactly.
- *Alternative:* URL-safe base64. Rejected — tokens travel in a query string but
  standard base64 is unambiguous at our id magnitudes and matches the intent's
  stated `base64(...)`. (If a token ever contained a `+`/`/` that broke a
  client, switch to URL-safe — a codec-local change.)
- *Alternative:* a signed/opaque server-stored token. Rejected — intent FR-9
  fixes the format and requires no server-side token store; ids are already
  monotonic and kind-scoped.

### D3. EPUB packaging is a minimal stdlib-only writer; `std.zip` here is read-side only
A direct check of the Zig 0.16 standard library shows `std/zip.zig` exposes the
ZIP container's pieces — `CompressionMethod` (`store = 0`, `deflate = 8`),
`local_file_header_sig`/`central_file_header_sig`/`end_record_sig`, and the
`LocalFileHeader`/`CentralDirectoryFileHeader`/`EndRecord` structs — plus an
*extractor* (`Iterator`, `extract`, `Decompress`), but **no high-level writer**.
The intent's §7 shorthand ("EPUB packaging — std.zip … write a ZIP") therefore
composes, rather than calls, a writer. The builder emits the EPUB by hand using
those exact stdlib structs (so the container format is not reinvented) and
DEFLATEs content bodies with `std.compress.flate.Compress`. Result: zero new
dependencies, single binary, and a writer small enough to audit.
- *Alternative:* vendor a ZIP-writer dependency. Rejected — violates
  stdlib-first; the stdlib primitives suffice and keep the binary
  dependency-free.
- *Alternative:* store every entry uncompressed (`store`). Rejected — XHTML
  bodies compress well; DEFLATE keeps EPUBs small for e-reader transfer.
  `mimetype` alone is stored, per EPUB validity.
- `// ponytail: hand-written ZIP writer from std.zip header structs +
  std.compress.flate; if Zig adds a std.zip writer, replace the emitter and keep
  the entry set.`

### D4. Absent or malformed `since` → `400`; first-download bootstrap is deferred to the UI change
US-004 permits either "from the beginning for that kind with a documented, safe
behavior" or "a clear 400." A valid token carries both kind and position. An
absent token carries neither, and inventing a kind would be guesswork that risks
a cross-kind leak — exactly what the success metric forbids. So the honest, lazy
rule is: **`since` is required and must decode to a known kind; otherwise
`400`.** The server is the sole issuer of advance tokens (FR-9); a client cannot
construct a valid advance token. The one gap this leaves — a client that has
never downloaded a kind and so holds no token — is a user-experience concern
owned entirely by the later embedded-UI change (US-007), the only caller in that
state; it can bootstrap via a documented initial-token mechanism it defines. No
bootstrap machinery is built now (You Aren't Gonna Need It — no caller exists).
- *Alternative:* treat absent `since` as "from the beginning of kind `news`".
  Rejected — silently picks a kind the client did not name; risks a cross-kind
  item and a wrong watermark.
- *Alternative:* accept a `kind` query param alongside an absent `since`.
  Rejected — two sources of kind truth (the param vs. a later token) invite
  drift; defer the whole bootstrap to the UI change.

### D5. "Nothing new" returns `204` and the same token; the next token reflects the last included id
When the store's range for `(token.kind, id > token.id)` is empty, the resolver
signals nothing-new and the server replies `204 No Content` with no
`X-Next-Token`, so the client keeps its token (intent US-004). When the range is
non-empty, `X-Next-Token = encode(kind, last_included_record.id)` — the id of the
newest item actually delivered, not "today" — so the next download resumes
exactly after the last delivered item even if newer items arrive between
requests. This is what makes the delivery gap-less and duplicate-free: the
watermark is always the maximal delivered id of that kind.
- *Alternative:* advance the token to "now" even on a partial batch. Rejected —
  could skip items curated between the range query and the response.

### D6. EPUB validity is enforced by a structural self-check, not an external checker
A generated EPUB must open on real readers (intent G4, §8). Rather than depend
on `epubcheck` in CI (an extra external tool), the builder ships a structural
self-check in `zig build test`: the generated bytes have `mimetype` as the first
entry with compression method `store` (0) and no extra data;
`META-INF/container.xml` exists and names the OPF path; the OPF manifest
references every per-item XHTML document; an EPUB 3 navigation document exists.
This catches the regressions that actually break readers (wrong mimetype
compression, dangling manifest refs, missing container) without a new CI
dependency. Full `epubcheck` can be added later as a non-blocking CI job.
- `// ponytail: structural self-check covers the reader-breaking shape; run
  epubcheck in CI as a follow-up if a real reader rejects a generated book.`

## Risks / Trade-offs

- **[Hand-written ZIP writer emits invalid containers]** → Mitigation: it
  composes the exact `std.zip` header structs and signatures rather than
  reinventing them (D3); the structural self-check (D6) fails the build on a
  malformed container before merge.
- **[An e-reader rejects a generated EPUB]** → Mitigation: the builder emits the
  EPUB 3 structure readers require (stored mimetype first, container.xml, OPF
  manifest, nav); the self-check validates that shape. Real-reader validation is
  a §8 success metric to confirm at integration, with `epubcheck` as an optional
  CI follow-up.
- **[Token replay yields duplicates]** → Mitigation: tokens are monotonic by id
  and the range is half-open `(token.id, ∞)`; the next token is the last
  delivered id (D5). Re-sending the same token yields the same delta; sending the
  returned token yields the next delta — never an overlap.
- **[Cross-kind leak in a download]** → Mitigation: the resolver ranges the
  store by `kind = token.kind`; the store's range query is already kind-scoped
  (archived `add-storage`). A news token can never return knowledge items.
- **[First-download has no token]** → Acknowledged non-goal (D4): `400` on
  absent/malformed `since`; the UI change (US-007) owns the bootstrap. No silent
  kind-guessing.
- **[Concurrent store append during a range read]** → Out of scope here (no
  writer is wired); the `add-storage` D6 ceiling adds synchronization at the
  first concurrent writer (the scheduler). Reads are over the in-memory index and
  are safe until then.

## Migration Plan

Greenfield and additive — no migration. Deploy by: nothing required at startup;
`/download` appears as a new protected route and returns `400` until a caller
supplies a valid token. No change to `/`, `/healthz`, `/metrics`, the store file,
or config. The new `download.zig` is exercised only by `zig build test` against
in-memory records until a later change wires real curation output into the store.
Rollback is `git revert` (the route and module disappear; existing endpoints are
unaffected).

## Open Questions

- None blocking. The first-download bootstrap (D4) is intentionally deferred to
  the US-007 UI change; if that change instead wants a server-provided
  initial-token endpoint, it adds it then. Whether the EPUB navigation document
  should be EPUB 3 (`nav`) only or also carry an NCX for older readers is an
  implementation detail resolved by emitting an EPUB 3 `nav` first and adding NCX
  only if a target reader needs it.
