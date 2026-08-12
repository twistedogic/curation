## Context

`curation` has, after six archived changes, every server-side ingredient for
delivery: the HTTP surface (config, lifecycle, `/healthz`, the bearer auth gate,
structured logging, `/metrics`), the pure curation pipeline ending at cap, feed
fetching + parsing, the `pi` longevity evaluator mapping survivors to a stream
`Kind` (`news`/`knowledge`), an append-only JSONL store with global monotonic
ids and a `range(kind, since_id)` half-open query, and the `download`
engine — a kind-scoped token codec, a stdlib-only EPUB builder, and a resolver
that turns a decoded token into the EPUB of the delta or a nothing-new signal.
The server wires `/download` to that engine, bearer-gated, returning
`200 application/epub+zip` + `X-Next-Token`, `204`, or `400`.

Two things are missing for a human to use any of it. First, `GET /` returns the
placeholder `"curation\n"` — there is no page. Second, `add-epub-download`
design D4 made an absent or malformed `since` a hard `400`, because a valid
token carries both kind and position and an absent token carries neither, so
inventing a kind would risk a cross-kind leak — exactly what the §8 success
metric forbids. That change explicitly deferred the first-download bootstrap to
"the US-007 UI change," the only caller in that no-token state.

`.see/intent.md` fixes the human-facing contract. US-007 / G8 / FR-13: a single
static page embedded via `@embedFile`, served at `GET /`, no framework, no build
step, no external assets; two buttons (news, knowledge); one last-download token
per kind plus the bearer held in `localStorage`; each button sends its token as
`since` to `GET /download`, triggers the EPUB as a Blob on `200`, stores
`X-Next-Token`, shows "nothing new" on `204` (token unchanged); the operator
pastes the bearer once; same-origin, so no Cross-Origin Resource Sharing (CORS).
FR-9 fixes the token as `base64("<kind>:<global_id>")`, opaque to the client,
monotonic, server-issued, kind-scoped — the server is the sole authority over
issuance. FR-10 lists `GET /` as an open endpoint. Decision #9 fixes
`localStorage` for download-token persistence across restarts; Decision #10
fixes the bearer-in-`localStorage`, page-unauth UX.

This change builds exactly that: the embedded page (a new `ui` capability), the
`GET /` route that serves it (a `server` addition), and the `/download`
bootstrap that lets a no-token client get a server-issued first token (a
`server` modification). It depends only on the already-built `/download` route,
the resolver (which already returns all of a kind for `id = 0`), and the auth
gate — none of which change. It is deliberately the human-delivery slice: the
daily scheduler/job (US-002), age-based retention (FR-16), and Lightpanda web
rendering (US-008) are later changes.

## Goals / Non-Goals

**Goals:**
- A pure-ish `ui` capability, invokable as a library, that exposes the embedded
  page bytes as a compile-time constant and whose content self-checks assert the
  page is self-contained (inlined CSS/JS, no external asset requests) and
  carries exactly two per-kind download affordances.
- A documented client-side behavior contract for the page: per-kind tokens and
  the bearer in `localStorage`; `GET /download?since=<token>` per kind; `200` →
  Blob download + store `X-Next-Token`; `204` → "nothing new", token unchanged;
  `401` → re-prompt bearer; only `X-Next-Token` ever writes a token.
- A first-download bootstrap owned client-side by the page (request
  `?kind=<kind>` with no `since`) and resolved server-side (synthesize
  `{ kind, 0 }`), so the client never constructs a token and the server stays
  the sole issuer.
- A `GET /` route serving the page verbatim as `text/html; charset=utf-8`, open.
- `zig build test` green: page self-containment self-check, `GET /` route, and
  the `/download` bootstrap paths.

**Non-Goals:**
- The daily scheduler and the fetch→curate→longevity→store job (US-002) — a
  later orchestration change. The store may be empty until then; `/download`
  (and thus the page) will return `204` until a later change populates it, which
  is correct, not a bug.
- A server-side token store or bootstrap endpoint separate from `/download` —
  the bootstrap is a query-parameter mode on the existing route, not a new
  endpoint (D3).
- Age-based retention / prune (FR-16), Lightpanda web rendering (US-008), and
  extended curation/source/`pi` Prometheus metrics (US-006) — separate slices.
- Rich UI: settings, history, per-item views, OPML editing. One page, two
  buttons (intent Non-Goals).
- Accessing `localStorage` or the DOM from Zig — the page's runtime logic is
  client JS; Zig owns only the static bytes and asserts on their content.
- Hardening the page against a hostile operator (the bearer lives in
  `localStorage`) — single-user, same-origin; accepted (D5).

## Decisions

### D1. The `ui` capability owns the page bytes and contract; serving and the bootstrap live in `server`
The page is static content; the only Zig over it is exposing the `@embedFile`
constant and asserting on its bytes. Serving those bytes at `GET /` is HTTP
routing + response shaping, which is the server's job, exactly mirroring how
`download` (the pure engine) is separated from the `/download` route in
`server.zig`. Likewise the bootstrap is input handling on an existing server
route (parse `kind`, synthesize a zero token, call the unchanged resolver), not
page logic and not a new download-capability behavior. So `ui` is a new
capability and `server` gains the `GET /` route and the `/download` bootstrap.
- *Alternative:* put `GET /` and the bootstrap inside `ui`. Rejected — it would
  split the HTTP surface across two capabilities and duplicate the
  auth/routing/metrics plumbing the server already owns.

### D2. One inlined HTML asset via a single `@embedFile`; no framework, no build step, no separate CSS/JS files
The intent (FR-13) is explicit: one static page, HTML + JS + CSS, `@embedFile`,
no framework, no build step, no external asset requests. The laziest faithful
realization is a single `src/ui.html` with inlined `<style>` and `<script>`,
embedded once by `src/ui.zig` as `@embedFile("ui.html")`. One asset, one
constant, zero build tooling, zero runtime asset requests, single binary. A
content self-check asserts there is no `<script src=...>`, no
`<link rel=stylesheet href=...>`, and no `://` attribute, so the "no external
requests" guarantee is enforced at `zig build test` time, not by inspection.
- *Alternative:* separate `index.html`/`app.js`/`style.css` embedded and served
  individually. Rejected — more `@embedFile`s, more routes or content-types, and
  external-ish requests unless inlined anyway; one inlined file is strictly
  simpler.
- *Alternative:* a JS framework or a bundler. Rejected — violates FR-13 and
  adds a build step + dependency for two buttons.

### D3. First-download bootstrap = absent `since` + valid `kind` on `/download`, synthesized server-side as `{ kind, 0 }`; the client never builds a token
The resolver already treats `id = 0` as "from the beginning of the kind" (the
`download` spec scenario "a since_id of zero returns all of the kind"), so a
first download is just a resolution at position zero. The only question is who
names the kind for a client that holds no token. Intent FR-9 makes the server
the sole token issuer and tokens opaque to the client, so the page must not
synthesize `base64("news:0")`. Instead the page sends `?kind=news` (no `since`),
and the server — already the authority — synthesizes `{ kind = news, id = 0 }`
and resolves normally, returning a server-issued `X-Next-Token`. This confines
the bootstrap to the existing route (no new endpoint), leaves the `download`
codec/builder/resolver untouched, and keeps the server the sole issuer of
advance tokens. The `add-epub-download` D4 rejection of a `kind` parameter does
not bind here: that rejection was about a `kind` param *competing* with a token
for kind truth, which only happens when `since` is present. This change makes
`kind` authoritative *only* when `since` is absent (there is no token to
conflict with) and ignored whenever `since` is present — so there is exactly one
source of kind truth per request.
- *Alternative:* a new `GET /token?kind=<kind>` endpoint returning an initial
  token, which the page then sends as `since`. Rejected — more surface (a new
  route, a new requirement, a two-step client flow) for no benefit over a
  query-parameter mode on the existing route.
- *Alternative:* let the page synthesize `base64("<kind>:0")`. Rejected —
  violates FR-9 (client must not construct tokens; server is sole issuer).
- *Alternative:* treat absent `since` as "from the beginning of `news`" with no
  `kind`. Rejected — silently picks a kind the client did not name and risks a
  cross-kind leak (the `add-epub-download` D4 reasoning).

### D4. `200` → Blob + store `X-Next-Token`; `204` → leave the token; `401` → re-prompt; nothing else writes a token
The watermark for a kind is exactly the last `X-Next-Token` the server returned.
On `200` the page triggers the EPUB body as a Blob download and stores
`X-Next-Token` for that kind; on `204` (nothing new, including a bootstrap on an
empty kind) it shows "nothing new" and leaves the token as-is (absent during
bootstrap, so the next attempt re-bootstraps); on `401` it re-prompts for the
bearer without touching any token. The page never writes a token from any other
source. This is what keeps delivery gap-less and duplicate-free across browser
restarts (the token persists in `localStorage`, intent Decision #9): the next
download of a kind always resumes after the last delivered item.
- *Alternative:* advance the token to "now" on a partial batch. Rejected — could
  skip items curated between the response and the next request (same reasoning as
  `add-epub-download` D5).

### D5. The page is open; the bearer lives in `localStorage`; same-origin, so no CORS
`GET /` is unauthenticated (intent FR-10, Decision #10) so the operator can load
it before entering the bearer. The bearer is entered once, held in
`localStorage` under `curation.bearer`, and sent as `Authorization: Bearer` only
on same-origin `/download`. The page and `/download` share an origin, so no
preflight, no `Access-Control-Allow-Origin`, no header gymnastics (intent §7).
A bearer in `localStorage` is readable by same-origin JS — acceptable for a
single-user, single-binary, same-origin tool; it is the same trust posture as
any bearer held by a non-browser client script.
- `// ponytail: bearer in localStorage, single-user/same-origin; add a
  short-lived session cookie + server-side auth flow only if a multi-user or
  cross-origin deployment appears.`

## Risks / Trade-offs

- **[Bearer token exposed in `localStorage`]** → Accepted (D5): single-user,
  same-origin, same posture as any client-held bearer. A same-origin
  content-injection bug would be the real risk; mitigated by serving only the
  static embedded bytes at `GET /` (no user-controlled content is ever rendered
  server-side) and by the page making no external requests (D2).
- **[A stale binary serves a stale page]** → Mitigated trivially: the page is
  `@embedFile`'d at compile time, so a redeploy always serves the page matching
  the binary; there is no separately-served asset to drift.
- **[Bootstrap on an empty kind loops]** → By design (D4): a bootstrap returns
  `204` and leaves the kind's token absent, so the next attempt re-bootstraps;
  once the orchestration change (US-002) populates the kind, the next bootstrap
  returns `200` + `X-Next-Token` and the kind leaves the bootstrap state. No
  client-side "first token" state is required.
- **[The page's JS has no automated browser test]** → The runtime JS is trivial
  (two handlers, `localStorage`, one `fetch`); its *contract* is pinned by the
  `ui` spec scenarios and asserted where it is statically determinable
  (self-containment, exactly two affordances). Full browser automation is out of
  scope for a stdlib-only Zig change; a follow-up may add it if the JS grows.
- **[Cross-kind leak via the bootstrap]** → Mitigated (D3): the server
  synthesizes `{ kind = <kind param>, 0 }` and the resolver is kind-scoped
  (archived `add-storage`, `add-epub-download`); a `kind=news` bootstrap can
  never return knowledge records.

## Migration Plan

Greenfield and additive — no migration. Deploy by: nothing required at startup;
`GET /` now returns the embedded download page instead of the placeholder
(`text/html; charset=utf-8`, still open, still no auth), and `GET /download`
additionally accepts a `kind` query parameter for the first-download bootstrap
(ignored whenever `since` is present). Existing non-browser clients that always
send a server-issued `since` are unaffected. No change to `/healthz`, `/metrics`,
the store file, or config. Rollback is `git revert` (the placeholder `GET /`
returns and the `kind` parameter is ignored/`400` again as before).

## Open Questions

- None blocking. Whether the "nothing new" UI state should also surface the
  kind's last-delivered date is a cosmetic detail left to the implementation; it
  needs no server change (the client knows only its token, not a date). If a
  target e-reader or client ever cannot follow the `kind`-parameter bootstrap,
  the fallback is the explicitly-rejected `GET /token` endpoint (D3), added then.
