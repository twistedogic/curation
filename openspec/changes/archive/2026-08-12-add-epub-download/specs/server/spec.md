## ADDED Requirements

### Requirement: Download endpoint

The system SHALL expose `GET /download?since=<token>` as a protected endpoint,
gated by the existing bearer-token authentication requirement (constant-time
comparison of the configured `auth_token`). The `since` query parameter SHALL be
a `download` capability token. For a request carrying a valid bearer token and a
`since` that decodes to `{ kind, id }`, the server SHALL resolve the incremental
download via the `download` capability: if the resolver signals nothing-new, the
server SHALL respond `204 No Content` with no body and no `X-Next-Token` header;
otherwise the server SHALL respond `200` with
`Content-Type: application/epub+zip`, the EPUB as the body, and an
`X-Next-Token` header set to the resolver's next token. A request whose `since`
parameter is absent, empty, or fails to decode SHALL respond
`400 Bad Request` with an empty body, without consulting the store. A request to
`/download` without a valid bearer token SHALL respond `401` without performing
any resolution, per the authentication requirement.

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

#### Scenario: an absent or malformed since returns 400

- **WHEN** a client sends `GET /download` (no `since`) or
  `GET /download?since=garbage` with the configured bearer token
- **THEN** the server responds `400 Bad Request` with an empty body, without
  reading the store

#### Scenario: a missing or wrong bearer token returns 401

- **WHEN** a client sends `GET /download?since=<valid token>` with no
  `Authorization` header or a non-matching token
- **THEN** the server responds `401` without resolving any download
