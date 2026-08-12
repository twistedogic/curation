## ADDED Requirements

### Requirement: EPUB generation observability

The download resolver SHALL accept an optional metrics recorder — a nullable
handle to the `server` capability's metrics registry — and, each time it resolves
a non-empty range into an EPUB, SHALL record into it exactly one EPUB
generation labeled by the resolved `kind` (`news` or `knowledge`). A nothing-new
resolution (an empty range, for which no EPUB is built) SHALL record nothing. A
`null` recorder SHALL record nothing and SHALL leave the resolver otherwise
unchanged. A recording failure SHALL be non-fatal: it SHALL be logged and SHALL
NOT abort the resolution, change the returned EPUB or next token, or alter the
half-open `(token.id, …]` range semantics. The recorded metrics are exposed by
the `server` capability's `/metrics` endpoint; the resolver SHALL perform no
HTTP serving, no daily scheduling, no store mutation, no token decode beyond
what the caller already supplied, and no longevity evaluation in this
requirement. The token codec, EPUB builder, EPUB structural validity, and
incremental download resolution requirements are unchanged by this requirement.

#### Scenario: a non-empty resolve records one generation for its kind

- **WHEN** the resolver is given a token of kind `news` whose range is non-empty
  and builds an EPUB, with a non-null recorder
- **THEN** the recorder has recorded exactly one EPUB generation for `kind=news`
  and none for `kind=knowledge`, and the returned EPUB and next token are
  unchanged from the same resolve with a null recorder

#### Scenario: the two kinds are recorded distinctly

- **WHEN** the resolver resolves one non-empty `news` range and one non-empty
  `knowledge` range, with a non-null recorder
- **THEN** the recorder has recorded one EPUB generation for `kind=news` and one
  for `kind=knowledge`, independently

#### Scenario: a nothing-new resolve records nothing

- **WHEN** the resolver is given a token whose range is empty (nothing new) and
  signals nothing-new, with a non-null recorder
- **THEN** the recorder has recorded no EPUB generation for either kind, because
  no EPUB was built

#### Scenario: a null recorder is a no-op and the resolution is unchanged

- **WHEN** the resolver resolves a non-empty range with a null recorder
- **THEN** it records nothing and returns the same EPUB bytes and next token it
  would with a recorder, so the resolver stays usable with no registry

#### Scenario: a recording failure is non-fatal

- **WHEN** the recorder cannot accept a recording (an allocator error) after an
  EPUB has been built
- **THEN** the resolver logs the recording failure, still returns the EPUB and
  the next token, and does not abort the download
