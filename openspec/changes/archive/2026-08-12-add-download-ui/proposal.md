## Why

After six archived changes `curation` can serve HTTP, fetch/parse feeds, run the
pure normalize/dedupe/filter/tag/cap pipeline, label each survivor's longevity
into a stream `Kind`, persist labeled records with global monotonic ids and a
per-kind range query, and deliver a per-kind incremental Electronic Publication
(EPUB) over a bearer-authed `GET /download` (`add-server`, `add-curation-pipeline`,
`add-feed-fetching`, `add-longevity-evaluator`, `add-storage`,
`add-epub-download`). But a human cannot drive any of it: there is no page, and
`GET /` returns a placeholder string. The product's human-facing contract —
intent US-007 / G8 / FR-13 — is a single embedded web page with one download
button per kind that runs the exact same incremental-download flow as any other
client, holding one last-download token per kind (and the bearer token) in
browser `localStorage`.

There is also one deliberate gap left by `add-epub-download`: a first-time
client holds no `since` token, and that change made an absent or malformed
`since` a hard `400` (design D4), explicitly deferring the first-download
bootstrap to "the US-007 UI change." This change is that change. It adds the
embedded page and resolves the bootstrap in the only place the intent permits —
server-side, with the server the sole issuer of tokens — so the client never
synthesizes or parses a token.

## What Changes

- Add a new **`ui` capability**: a single static HyperText Markup Language
  (HTML) page with inlined JavaScript (JS) and Cascading Style Sheets (CSS),
  embedded into the binary at compile time via `@embedFile` (no framework, no
  build step, no external asset requests). The page renders exactly two download
  affordances — `news` and `knowledge` — and holds, in `localStorage`, one
  last-download token per kind (`curation.token.news`, `curation.token.knowledge`)
  and the bearer token (`curation.bearer`).
- Define the **client-side behavior contract** the page implements: each button
  sends `Authorization: Bearer <bearer>` and the kind's stored token as `since`
  to same-origin `GET /download`; on `200` it triggers the EPUB as a binary large
  object (Blob) download and stores the response's `X-Next-Token` for that kind;
  on `204` it shows "nothing new" and leaves the token unchanged; on `401` it
  re-prompts for the bearer. Only an `X-Next-Token` header ever writes a token.
- Own the **first-download bootstrap**: when a kind has no stored token, the page
  requests `GET /download?kind=<kind>` (no `since`); the server resolves the
  beginning of that kind and returns a server-issued `X-Next-Token`, ending the
  bootstrap. The page never constructs a token locally — the server remains the
  sole token issuer (intent FR-9).
- Modify the **`GET /download` route** to honor this bootstrap: an absent `since`
  together with a valid `kind` (`news`/`knowledge`) is resolved as the kind's
  zero-position token `{ kind, id = 0 }` (the resolver already returns all of a
  kind for `id = 0`); an absent `since` with no `kind` or an unknown `kind` stays
  `400`. When `since` is present, `kind` is ignored — the token is the sole
  source of kind.
- Add a **`GET /` route** that serves the `ui` page bytes verbatim as
  `text/html; charset=utf-8`, open (no auth), replacing the placeholder.
- Standard library only; `zig build test` stays green. No daily scheduler,
  retention, or Lightpanda in this change — those remain later slices.

## Capabilities

### New Capabilities
- `ui`: The embedded single-page download UI — a static HTML/JS/CSS document
  embedded via `@embedFile` and its documented client-side behavior contract
  (one download affordance per kind, per-kind tokens and the bearer held in
  `localStorage`, the `/download` request/response flow, and the first-download
  bootstrap via the `kind` parameter). Owns no HTTP serving, EPUB generation,
  token codec, store access, fetching, longevity evaluation, or scheduling.

### Modified Capabilities
- `server`: gains an open `GET /` route serving the `ui` page verbatim; and its
  `GET /download` endpoint gains the first-download bootstrap (absent `since` +
  valid `kind` → resolve that kind from the beginning; `kind` ignored when
  `since` is present; absent `since` with no/unknown `kind` stays `400`).
  Authentication-first (`401` before any resolution) and the existing
  `since`-present behavior are unchanged.

## Impact

- **Code:** new `src/ui.zig` exposing the embedded page constant and its
  content self-checks, plus a new `src/ui.html` asset (inlined CSS/JS);
  `src/server.zig` replaces the `GET /` placeholder branch with the embedded-page
  response and extends `handleDownload` to recognize the `kind`-parameter
  bootstrap; `src/main.zig` registers `ui.zig` in its comptime test import block.
  The `download` codec/builder/resolver, the store, and the auth gate are
  consumed unchanged.
- **APIs:** `GET /` changes from a placeholder to the embedded download page
  (`text/html; charset=utf-8`, still open). `GET /download` gains an optional
  `kind` query parameter used only when `since` is absent (bootstrap); its
  `since`-present contract is unchanged. No change to `/healthz` or `/metrics`.
- **Dependencies:** none added — Zig 0.16 standard library only (`@embedFile`).
  Stays a single binary; the page is bytes compiled into it, not a served asset
  directory.
- **Data:** no new persistent server-side files. Client-side state is three
  `localStorage` keys (`curation.token.news`, `curation.token.knowledge`,
  `curation.bearer`); no server-side token store (tokens remain stateless
  encodings of store ids, server-issued via `X-Next-Token`).
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the page
  self-containment self-check, the `GET /` route, and the `/download` bootstrap
  paths (200-from-beginning, 204-on-empty-kind, 400-on-no/unknown-kind,
  kind-ignored-when-since-present, 401-before-resolution).
