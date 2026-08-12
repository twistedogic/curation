# download Specification

## Purpose
The pure incremental-delivery engine — a kind-scoped download-token codec, a
kind-parametric EPUB builder (standard library only), and a resolver that turns
a token plus the storage range query into either an EPUB of the delta or a
"nothing new" signal. Owns no HTTP serving, no fetching, no scheduling, no
storage, and no longevity evaluation.
## Requirements
### Requirement: Kind-scoped download tokens

The system SHALL encode a download position as a token equal to the standard
base64 (RFC 4648) encoding of the ASCII bytes `"<kind>:<id>"`, where `<kind>`
is `news` or `knowledge` and `<id>` is the global monotonic store id (`u64`).
`encode(kind, id) -> []u8` SHALL be the sole producer of tokens, and
`decode(token) -> { kind, id }` SHALL be the sole consumer. `decode` SHALL fail
for any input that is not valid standard base64, that does not contain exactly
one `:` separating a known kind (`news`/`knowledge`) from a base-10 `u64`, or
whose id is not a non-negative integer. Tokens SHALL be opaque to the client and
SHALL carry no information beyond kind and id. The codec SHALL perform no HTTP
serving, store access, scheduling, or EPUB generation.

#### Scenario: encode then decode round-trips

- **WHEN** `encode(.news, 7)` is computed and the result is passed to `decode`
- **THEN** `decode` returns `{ kind = news, id = 7 }`

#### Scenario: a malformed token fails to decode

- **WHEN** `decode` is given the input `not-a-token`
- **THEN** it returns an error and yields no kind or id

#### Scenario: an unknown kind fails to decode

- **WHEN** `decode` is given a base64 encoding of `sports:3`
- **THEN** it returns an error (the kind is neither `news` nor `knowledge`)

#### Scenario: the two kinds encode distinctly

- **WHEN** `encode(.news, 1)` and `encode(.knowledge, 1)` are computed
- **THEN** the two tokens differ, each decoding back to its own kind and id 1

### Requirement: Per-kind EPUB generation

The system SHALL provide a pure EPUB builder that, given a `Kind` and the
records of that kind in ascending id order, produces a complete EPUB file as an
in-memory byte buffer, performing no network, filesystem, subprocess, or HTTP
I/O. The buffer SHALL be a ZIP container whose first entry is named `mimetype`
with compression method `store` (0) and the exact content
`application/epub+zip`; it SHALL contain `META-INF/container.xml` that points at
the Open Packaging Format (OPF) package file; it SHALL contain an OPF package
with a manifest referencing one Extensible Hypertext Markup Language (XHTML)
content document per record plus an EPUB 3 navigation document; and it SHALL
contain one XHTML content document per record carrying that record's title and
body. The builder SHALL be kind-parametric — the same code SHALL build both the
news and knowledge EPUBs, differing only in the supplied kind and records. The
builder SHALL use the Zig standard library only (`std.zip` container definitions
and `std.compress.flate` for DEFLATE) and SHALL introduce no new dependency.

#### Scenario: building yields an EPUB for the given kind

- **WHEN** the builder is given kind `news` and two news records in ascending id
  order
- **THEN** it returns a byte buffer that is a ZIP container whose `mimetype`
  entry is `application/epub+zip`, stored first and uncompressed, and that
  contains one XHTML content document per record

#### Scenario: the same builder builds both kinds

- **WHEN** the builder is run once with kind `news` and its records and once
  with kind `knowledge` and its records
- **THEN** both calls succeed and each resulting EPUB reflects only the kind and
  records it was given

#### Scenario: building is pure of side effects

- **WHEN** the builder runs
- **THEN** it performs no reads from or writes to the network, the filesystem,
  any child process, or any HTTP connection

#### Scenario: no dependency is introduced

- **WHEN** the module is compiled
- **THEN** `build.zig.zon` declares no new dependency and only the standard
  library is imported for ZIP/DEFLATE handling

### Requirement: EPUB structural validity

A generated EPUB SHALL satisfy the structural conditions common e-readers
require. The `mimetype` entry SHALL be the first entry in the ZIP, stored with
compression method `store` (0) and no extra field. `META-INF/container.xml`
SHALL exist and SHALL reference the OPF package file by path. The OPF manifest
SHALL reference every XHTML content document the builder emitted and the
navigation document. The builder SHALL be validated by a structural self-check
in `zig build test` that asserts these conditions on a generated EPUB; the
self-check SHALL fail the build if any condition is violated.

#### Scenario: mimetype is stored first and uncompressed

- **WHEN** the self-check inspects a generated EPUB's ZIP entries in order
- **THEN** the first entry is `mimetype`, its compression method is `store` (0),
  and its content is exactly `application/epub+zip`

#### Scenario: container.xml points at the OPF

- **WHEN** the self-check reads `META-INF/container.xml` from a generated EPUB
- **THEN** it names an OPF package file that is present in the container

#### Scenario: the manifest references every content document

- **WHEN** the self-check reads the OPF manifest of an EPUB built from N records
- **THEN** the manifest references the navigation document and exactly N XHTML
  content documents, and each referenced file exists in the container

### Requirement: Incremental download resolution

The system SHALL provide a resolver that, given a decoded token `{ kind, id }`
and a store, returns either the EPUB of the delta or a nothing-new signal, as
follows. It SHALL query the store (via the storage capability's range query) for
the records of `kind` whose id is strictly greater than `id` (the half-open range
`id > token.id`). When the range is empty, the resolver SHALL signal nothing-new
and SHALL produce no EPUB and no next token. When the range is non-empty, the
resolver SHALL build the EPUB from those records in ascending id order (per the
EPUB builder requirement) and SHALL return the EPUB together with a next token
equal to `encode(kind, last_included_record.id)`, where `last_included_record`
is the record with the greatest id in the range. The next token SHALL never be
less than the input token's id. The resolver SHALL consider only records of
`token.kind` and SHALL never return a record of the other kind. The resolver
SHALL not mutate the store and SHALL perform no HTTP serving or scheduling.

#### Scenario: a non-empty range yields the EPUB and the next token

- **WHEN** the resolver is given token `{ news, 1 }` against a store whose news
  ids are `[1, 3, 5]`
- **THEN** it returns an EPUB built from the news records with ids 3 and 5, and a
  next token that decodes to `{ news, 5 }`

#### Scenario: an empty range signals nothing new

- **WHEN** the resolver is given token `{ news, 5 }` against a store whose
  largest news id is 5
- **THEN** it signals nothing-new, returns no EPUB, and returns no next token

#### Scenario: the delta never overlaps the token

- **WHEN** the resolver is given token `{ knowledge, 2 }` against a store whose
  knowledge ids are `[2, 4]`
- **THEN** the returned EPUB contains only the knowledge record with id 4, and
  the next token decodes to `{ knowledge, 4 }`

#### Scenario: the resolver never crosses kinds

- **WHEN** the resolver is given a `news` token against a store containing both
  news and knowledge records with ids greater than the token's id
- **THEN** the returned EPUB contains only news records

#### Scenario: a since_id of zero returns all of the kind

- **WHEN** the resolver is given token `{ news, 0 }` against a store with news
  ids `[1, 3, 5]`
- **THEN** it returns an EPUB built from all three news records and a next token
  that decodes to `{ news, 5 }`

### Requirement: Capability boundary

The download capability SHALL own the token codec, the EPUB builder, and the
incremental resolver only. It SHALL perform no HTTP serving, no feed fetching,
no curation pipeline stage, no longevity evaluation, no item storage, no daily
scheduling, and no age-based retention. It SHALL read the store only through the
storage capability's range query and SHALL not mutate it. It SHALL be invokable
as a library.

#### Scenario: the download engine owns no serving, fetching, or storage mutation

- **WHEN** the token codec, EPUB builder, and resolver run
- **THEN** they perform no HTTP serving, no feed fetching, no `pi` invocation,
  no store mutation, and no scheduling

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

### Requirement: Well-formed item content documents

The EPUB builder SHALL XML-escape every record's `title` and `body` wherever it
emits them into the EPUB — in each item's XHTML content document (the
`<head><title>`, the `<h1>` heading, and the `<p>` body) and in the navigation
document's table-of-contents link text — so that a record whose `title` or
`body` contains any of `&`, `<`, `>`, `"`, or `'` still yields well-formed XHTML.
Escaping SHALL replace `&` with `&amp;`, `<` with `&lt;`, `>` with `&gt;`, `"`
with `&quot;`, and `'` with `&#39;`, applied to the record text only and never to
the static XHTML markup the builder emits. The `&`-to-`&amp;` replacement SHALL
be applied before any other, so an input `&` is not double-escaped. The token
codec, the OPF package, the ZIP container structure (mimetype first and stored,
`META-INF/container.xml`, the OPF manifest and spine), the kind-parametric
builder contract, the incremental resolver and its half-open `(token.id, …]`
range, and the observability recorder are unchanged; only the textual content of
the emitted documents is escaped.

#### Scenario: an ampersand and angle brackets in a title are escaped

- **WHEN** the builder emits a content document for a record whose `title` is
  `A & B < C`
- **THEN** the document's `<head><title>` and `<h1>` contain `A &amp; B &lt; C`,
  no bare `&` or `<` from the record reaches the document, and the document is
  well-formed XHTML

#### Scenario: markup characters in a body are escaped

- **WHEN** the builder emits a content document for a record whose `body` is
  `if x < 5 && y > 3 { print("hi") }`
- **THEN** the document's `<p>` body contains the text with every `<` as
  `&lt;`, every `>` as `&gt;`, every `&` as `&amp;`, and every `"` as `&quot;`,
  and the document is well-formed XHTML

#### Scenario: the navigation link text is escaped

- **WHEN** the builder emits the navigation document for records whose titles
  include `A & B` and `<script>`
- **THEN** each `<a>` link's text in the table of contents is escaped
  (`A &amp; B` and `&lt;script&gt;`) and the navigation document is well-formed
  XHTML, while the `href` attribute (the index-derived filename) is unchanged

#### Scenario: a single quote in record text is escaped

- **WHEN** the builder emits a content document for a record whose `title` is
  `it's`
- **THEN** the title text in the document is `it&#39;s` (the `'` becomes
  `&#39;`) and the document is well-formed XHTML

#### Scenario: markup-free text is emitted verbatim

- **WHEN** the builder emits a content document for a record whose `title` is
  `Alpha` and whose `body` is `first`
- **THEN** the document's title and body text are `Alpha` and `first` verbatim,
  with no spurious entity introduced, so escaping does not alter markup-free
  content

#### Scenario: the self-check rejects an unescaped content document

- **WHEN** `zig build test` runs the EPUB self-check against an EPUB built from a
  record whose `title` is `A & B < C` and whose `body` is `x < y & z`
- **THEN** the self-check asserts the emitted content document and the navigation
  link text escape the record text (it fails the build if a bare `&` or `<` from
  the record reaches either document), so this regression cannot silently return

