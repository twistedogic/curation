## MODIFIED Requirements

### Requirement: Download endpoint

The system SHALL expose `GET /download` as a protected endpoint, gated by the
existing bearer-token authentication requirement (constant-time comparison of
the configured `auth_token`). Resolution SHALL be controlled by two query
parameters: `since` (a `download` capability token) and, for first-download
bootstrap only, `kind` (`news` or `knowledge`).

Authentication SHALL precede all resolution: a request to `/download` without a
valid bearer token SHALL respond `401` without performing any resolution or
consulting the store.

When `since` is present, it SHALL be decoded to `{ kind, id }` and the token
SHALL be the sole source of kind; a `kind` parameter, if also present, SHALL be
ignored. A `since` that is empty or fails to decode SHALL respond
`400 Bad Request` with an empty body, without consulting the store.

When `since` is absent, the request is a first-download bootstrap: the server
SHALL require a `kind` parameter. If `kind` is absent or is not one of
`news`/`knowledge`, the server SHALL respond `400 Bad Request` with an empty
body, without consulting the store. If `kind` is valid, the server SHALL resolve
the download exactly as if the token were `{ kind = <kind>, id = 0 }` — the
beginning of that kind — producing the same outcomes as any other resolution.

For a valid bearer token and a resolved position `{ kind, id }`, the server
SHALL resolve the incremental download via the `download` capability: if the
resolver signals nothing-new, the server SHALL respond `204 No Content` with no
body and no `X-Next-Token` header; otherwise the server SHALL respond `200` with
`Content-Type: application/epub+zip`, the EPUB as the body, and an
`X-Next-Token` header set to the resolver's next token. The server SHALL be the
sole issuer of advance tokens (those returned in `X-Next-Token`); no advance
token is ever client-supplied.

#### Scenario: a valid token with new items returns the EPUB and a next token

- **WHEN** a client sends `GET /download?since=<token for {news,1}>` with the
  configured bearer token, against a store whose news ids are `[1, 3, 5]`
- **THEN** the server responds `200`, `Content-Type: application/epub+zip`, a
  body that is a valid EPUB of the news records with ids 3 and 5, and an
  `X-Next-Token` header that decodes to `{ news, 5 }`

#### Scenario: nothing new returns 204 and no next token

- **WHEN** a client sends `GET /download?since=<token for {news,5}>` with the
  configured bearer token, against a store whose largest news id is 5
- **THEN** the server responds `204 No Content` with no body and no
  `X-Next-Token` header

#### Scenario: a present but empty or malformed since returns 400

- **WHEN** a client sends `GET /download?since=garbage` (or an empty `since`)
  with the configured bearer token
- **THEN** the server responds `400 Bad Request` with an empty body, without
  reading the store

#### Scenario: a missing or wrong bearer token returns 401

- **WHEN** a client sends `GET /download?since=<valid token>` with no
  `Authorization` header or a non-matching token
- **THEN** the server responds `401` without resolving any download

#### Scenario: an absent since with a valid kind bootstraps from the beginning

- **WHEN** a client sends `GET /download?kind=news` (no `since`) with the
  configured bearer token, against a store whose news ids are `[1, 3, 5]`
- **THEN** the server responds `200`, `Content-Type: application/epub+zip`, a
  body that is a valid EPUB of all three news records, and an `X-Next-Token`
  header that decodes to `{ news, 5 }`

#### Scenario: a bootstrap on an empty kind returns 204

- **WHEN** a client sends `GET /download?kind=knowledge` (no `since`) with the
  configured bearer token, against a store with no knowledge records
- **THEN** the server responds `204 No Content` with no body and no
  `X-Next-Token` header

#### Scenario: a bootstrap with no kind or an unknown kind returns 400

- **WHEN** a client sends `GET /download` (no `since`, no `kind`) or
  `GET /download?kind=sports` with the configured bearer token
- **THEN** the server responds `400 Bad Request` with an empty body, without
  reading the store

#### Scenario: the kind parameter is ignored when since is present

- **WHEN** a client sends `GET /download?since=<token for {knowledge,2}>&kind=news`
  with the configured bearer token, against a store whose knowledge ids are
  `[2, 4]`
- **THEN** the server resolves `knowledge` (the token's kind), ignoring the
  `kind=news` parameter, and returns the knowledge record with id 4

## ADDED Requirements

### Requirement: Embedded download UI endpoint

The system SHALL serve the `ui` capability's embedded static download page at
`GET /` with `Content-Type: text/html; charset=utf-8`, returning the page bytes
verbatim with no server-side templating or substitution. This endpoint SHALL be
open (not subject to the bearer-token authentication gate), so an operator can
load it before entering the bearer token. The page makes no request requiring
authentication other than same-origin `GET /download`, which it authorizes with
a client-held bearer token.

#### Scenario: the root path serves the embedded page

- **WHEN** a client sends `GET /`
- **THEN** the server responds `200`, `Content-Type: text/html; charset=utf-8`,
  and a body equal to the `ui` capability's embedded page bytes verbatim

#### Scenario: the root path is open

- **WHEN** a client sends `GET /` with no credentials
- **THEN** the server responds `200` (not `401`)
