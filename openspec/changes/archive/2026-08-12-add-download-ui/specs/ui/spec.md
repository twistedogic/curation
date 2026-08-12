## ADDED Requirements

### Requirement: Embedded single-page download UI

The system SHALL provide a single static HyperText Markup Language (HTML)
document, with its JavaScript (JS) and Cascading Style Sheets (CSS) inlined,
embedded into the binary at compile time via `@embedFile`. The document SHALL
use no JS framework, SHALL require no build step, and SHALL make no asset
request to any origin other than the server itself. The embedded bytes SHALL be
exposed as a compile-time constant so a caller serves them verbatim, and the
module SHALL use the standard library only and SHALL introduce no new
dependency.

#### Scenario: the page is self-contained

- **WHEN** the embedded document is inspected
- **THEN** it contains no `<script src=...>` element, no
  `<link rel="stylesheet" href=...>` element, and no attribute value containing
  `://`; all JS and CSS is inlined

#### Scenario: the page is embedded at compile time

- **WHEN** the module is compiled
- **THEN** `build.zig.zon` declares no new dependency and the page is available
  as a compile-time `@embedFile` constant

#### Scenario: no dependency is introduced

- **WHEN** the module is compiled
- **THEN** only the Zig standard library is imported and no package is added to
  `build.zig.zon`

### Requirement: Per-kind download affordances and client token state

The page SHALL render exactly two download affordances, one for kind `news` and
one for kind `knowledge`, and no other. It SHALL persist, in browser
`localStorage`, exactly one last-download token per kind under the stable keys
`curation.token.news` and `curation.token.knowledge`, and the bearer token under
the key `curation.bearer`. When an affordance is activated and a token for its
kind is already stored, the page SHALL issue a same-origin `GET /download`
request whose `since` query parameter is that kind's stored token and whose
`Authorization` header is `Bearer <curation.bearer>`.

#### Scenario: exactly two affordances, one per kind

- **WHEN** the page is inspected
- **THEN** it renders one download affordance for `news` and one for
  `knowledge`, and no other download affordance

#### Scenario: a stored token is sent as since

- **WHEN** the `news` affordance is activated and `curation.token.news` holds a
  token `T` and `curation.bearer` holds `B`
- **THEN** the page issues `GET /download?since=T` with header
  `Authorization: Bearer B`

#### Scenario: per-kind tokens are independent

- **WHEN** the `knowledge` affordance is activated
- **THEN** it sends the `curation.token.knowledge` value (not the news token) as
  `since`

### Requirement: First-download bootstrap per kind

When a kind's `localStorage` token is absent, the page SHALL issue that kind's
download as a bootstrap: a same-origin `GET /download` carrying the bearer token
and a `kind` query parameter set to that kind (`news` or `knowledge`), with no
`since` parameter. The page SHALL NOT synthesize or guess a token locally; it
SHALL rely on the server to resolve a first download from the `kind` parameter.
On receiving an `X-Next-Token` response header the page SHALL store it under that
kind's `localStorage` key, after which subsequent downloads of that kind send it
as `since`.

#### Scenario: no stored token bootstraps via the kind parameter

- **WHEN** the `news` affordance is activated and `curation.token.news` is unset
- **THEN** the page issues `GET /download?kind=news` (no `since`) with the bearer
  header, and sends no locally synthesized token

#### Scenario: a returned next token ends the bootstrap for that kind

- **WHEN** a bootstrap `GET /download?kind=news` responds `200` with
  `X-Next-Token: T`
- **THEN** the page stores `T` under `curation.token.news`, and the next `news`
  download sends `since=T`

### Requirement: Per-kind download response handling

For each kind's download request the page SHALL: on HTTP `200`, treat the
response body as a binary large object (Blob) and trigger an EPUB download, and
store the response's `X-Next-Token` header into that kind's `localStorage` token
key; on HTTP `204`, show a "nothing new" state for that kind and leave that
kind's `localStorage` token unchanged; on HTTP `401`, prompt for the bearer
token without changing any token. The page SHALL never write a token to
`localStorage` other than one received in an `X-Next-Token` header.

#### Scenario: a 200 triggers the EPUB download and stores the next token

- **WHEN** a kind's download responds `200` with an EPUB body and
  `X-Next-Token: T`
- **THEN** the page triggers a download of the body and stores `T` under that
  kind's token key

#### Scenario: a 204 leaves the token unchanged

- **WHEN** a kind's download responds `204`
- **THEN** the page shows "nothing new" for that kind and does not modify that
  kind's `localStorage` token

#### Scenario: a 401 does not change any token

- **WHEN** a kind's download responds `401`
- **THEN** the page prompts for the bearer token and leaves both the bearer and
  the kind tokens unchanged

#### Scenario: only server-issued next tokens are stored

- **WHEN** the page handles download responses
- **THEN** it writes a kind's token only from an `X-Next-Token` header, never
  from the request or any other source

### Requirement: Bearer token entry

The page SHALL let the operator enter the bearer token once, store it under
`curation.bearer`, and send it as `Authorization: Bearer` on every `/download`
request. The page served at `GET /` SHALL itself require no authentication.

#### Scenario: the bearer is entered once and reused

- **WHEN** the operator enters bearer `B` and then activates a download
- **THEN** the request carries `Authorization: Bearer B`, and the page sends
  `Bearer B` on subsequent downloads without re-prompting

#### Scenario: the page itself is unauthenticated

- **WHEN** a client requests `GET /` with no credentials
- **THEN** the page is served (not `401`)

### Requirement: Capability boundary

The `ui` capability SHALL own only the embedded static download page and its
documented client-side behavior. It SHALL own no HTTP serving, no EPUB
generation, no token encoding or decoding, no store access, no feed fetching, no
longevity evaluation, and no scheduling. It SHALL be invokable as a library that
yields the page bytes.

#### Scenario: the UI owns no serving, codec, or storage

- **WHEN** the `ui` module is consulted for the page bytes
- **THEN** it performs no HTTP serving, no token encode/decode, no store access,
  no `pi` invocation, and no scheduling
