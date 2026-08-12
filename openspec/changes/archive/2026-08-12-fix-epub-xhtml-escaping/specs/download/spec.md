## ADDED Requirements

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
