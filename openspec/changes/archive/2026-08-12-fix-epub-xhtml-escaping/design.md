## Context

`curation`'s acquire → curate → classify → store → serve path is fully built
(twelve archived changes; every capability named in `.see/intent.md` has a merged
specification; `openspec validate --all` is green). The `download` capability
(`add-epub-download`) builds a per-kind EPUB in memory from the JSONL store's
records and hands it to the `server` capability's `GET /download` resolver. Its
builder emits four kinds of document into the ZIP container: the stored
`mimetype`, `META-INF/container.xml`, an OPF package, a navigation document, and
one XHTML content document per record.

Intent **G4** demands a *valid* EPUB that renders on common e-readers. The
builder is correct about the container — the "EPUB structural validity"
requirement's self-check asserts `mimetype` is first and stored, that
`container.xml` points at the OPF, and that the manifest references every content
document and the nav. It is *not* correct about the documents' textual content.
`renderItem` and `renderNav` write each record's `title` and `body` into XHTML
with a bare `{s}`:

```
<head><title>{title}</title></head>
<h1>{title}</h1>
<p>{body}</p>
…
<li><a href="item{i}.xhtml">{title}</a></li>
```

The `sources` capability's tolerant parser is explicit, in its "Tolerant field
extraction" requirement, that it *decodes* the XML character entities (`&amp;`,
`&lt;`, …) and *unwraps* `<![CDATA[…]]>` sections before the item ever leaves
acquisition. So the bytes the store holds — and that `build` receives — carry
literal `&`, `<`, `>`, `"`, `'` whenever the source did. Interpolating those raw
into XHTML yields `<h1>A & B < C</h1>`, which is not well-formed XML: a bare `&`
is an undefined entity reference and a bare `<` starts a tag the parser cannot
close. The structural self-check never decodes a content document, so it stays
green while the EPUB an e-reader (or `epubcheck`) opens is malformed. Every other
markup/serialization boundary in the system is already handled — `std.json`
escapes the JSONL store, `pi` takes raw text on stdin, the UI is a static page
with no server-side substitution — so the EPUB's emitted XHTML is the single
remaining place record text is written into a markup context, and the only one
that does not escape.

This change closes that one defect with the smallest diff that does it: escape
record text at the two emission points that already exist, and extend the one
self-check that already builds and inspects an EPUB. It touches only the
`download` capability and changes no contract, store, route, token, or
container structure.

## Goals / Non-Goals

**Goals:**
- A `download` EPUB builder that emits well-formed XHTML content documents and a
  well-formed navigation document for *any* record, including titles/bodies that
  contain `&`, `<`, `>`, `"`, or `'`, by XML-escaping record text at every
  emission point (`renderItem`'s `<head><title>`, `<h1>`, and `<p>`; `renderNav`'s
  `<a>` link text).
- An extended `zig build test` EPUB self-check that builds an EPUB from a
  hostile record and asserts the escaping in both the content document and the
  navigation link text, failing the build if a bare `&` or `<` from a record
  reaches either document.
- `openspec validate fix-epub-xhtml-escaping` passes; `openspec validate --all`
  stays green; `zig build test` stays green.

**Non-Goals:**
- No HTML-to-XHTML sanitization, no tag stripping, no Markdown rendering. The
  body is whatever the source produced (feed text or Lightpanda's markdown dump);
  this change only guarantees the emitted XML is *well-formed*, not that the body
  is semantic XHTML. A body that is already valid markup-free text (the common
  case after entity decoding) renders unchanged.
- No change to the OPF package. Its `dc:identifier`, `dc:title`, manifest, and
  spine carry only the kind tag and index-derived item ids, never record text, so
  they need no escaping and are untouched.
- No change to the `sources` parser. Decoding entities/CDATA at acquisition is
  correct — record text should be raw everywhere except the one markup context
  it is emitted into. Escaping at the EPUB boundary, not at storage, keeps a
  single root-cause fix and leaves stored text unmodified.
- No change to the token codec, the ZIP writer, the incremental resolver and its
  half-open `(token.id, …]` range, the capability boundary, the observability
  recorder, any route, status code, auth ordering, store, config, or eval cache.
- No new dependency, no vendored XML library, no `epubcheck` in CI. Zig 0.16
  standard library only.

## Decisions

### D1 — Escape at the EPUB emission boundary, not at storage or in the pipeline

Record text is consumed in several places: the JSONL store (escaped by
`std.json`), the `pi` longevity evaluator (raw text on stdin — exactly what we
want), and the EPUB builder (a markup context). Escaping once at storage would
either double-escape the JSONL or force every consumer to unescape; escaping in
the curation pipeline would corrupt the text `pi` receives. The lazy,
root-cause fix is to escape at the single boundary where raw text is wrong — the
EPUB's XHTML emission — so the bug is fixed once, where every record funnels
through `renderItem`/`renderNav`, and no other consumer changes. This mirrors
the project's existing boundary discipline (each capability owns its own
serialization).

### D2 — Escape all five XML special characters, not just `&` and `<`

Record text enters element content (the `<h1>`, `<p>`, nav link text, and
`<head><title>`) today, where only `&` and `<` are strictly required. Escaping
`>`, `"`, and `'` too costs nothing (a five-entry scan), is uniformly correct,
and makes the helper safe if record text ever lands in an attribute value later
(e.g. a future `<a href>` carrying a record URL). Lazy here means picking the
robust correct option over the barely-sufficient one. The mapping is the
standard XML set: `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `"`→`&quot;`,
`'`→`&#39;` (numeric for `'`, since `&apos;` is not valid in raw HTML parsers).

### D3 — Replace `&` before the other characters

A naive single-pass replacement that emits `&amp;` for `&` and then scans the
output again would double-escape (`&lt;` → `&amp;lt;`). The escaper replaces
`&` first and writes each replacement once in a single forward pass, so an input
`&` becomes exactly `&amp;` and an input `<` becomes exactly `&lt;`. This is
the one edge case the self-check names explicitly (a body containing `&&`
yields `&amp;&amp;`, not `&amp;amp;&amp;amp;`).

### D4 — One small stdlib-only helper; no vendored XML library

Zig 0.16 stdlib has no XML escaper, but XML escaping is a five-character scan
and replace — a handful of lines over an `std.Io.Writer.Allocating` (the same
writer `renderOpf`/`renderNav` already use). No dependency is added; `build.zig.zon`
is unchanged. This is the same "hand-roll the tiny thing the stdlib lacks"
choice the project already made for the ZIP writer, the feed scanner, and the
logging writer.

`// ponytail: hand-rolled XML escaper (5-char scan); replace with a stdlib
// helper if Zig ever ships one (std.xml). Same shape as the hand-written ZIP
// writer and feed scanner.`

### D5 — Extend the existing EPUB self-check, do not add a parallel harness

`src/download.zig` already has a structural self-check (`test "build: structural
self-check — …"`) that builds an EPUB and inspects it through the private
`readZipEntries`/`findEntry` helpers. Extending that path — building an EPUB from
a hostile record and asserting the content document and nav link text escape it
— reuses the harness, keeps the assertion next to the code it guards, and fails
`zig build test` (the project's single test entry point) if the regression
returns. No separate test runner, no `epubcheck` dependency.

### D6 — Leave the OPF package untouched

`renderOpf` emits `dc:identifier`, `dc:title`, manifest `<item>` ids/hrefs, and
spine `itemref` idrefs — all derived from the kind tag (`news`/`knowledge`) and
the record index, never from record `title`/`body`. There is no record text in
the OPF, so there is nothing to escape, and touching it would only risk
regressing the manifest/spine the structural self-check already pins. The fix is
scoped to `renderItem` and `renderNav`.

## Risks / Trade-offs

- **The only behavior change is to markup-bearing text; plain text is
  byte-identical.** A record whose `title`/`body` contain none of the five
  characters is emitted verbatim — escaping is a no-op on it (asserted by the
  "markup-free text is emitted verbatim" scenario). So the fix cannot regress the
  common case; it only changes documents that were already malformed.
- **Content-document size grows with markup-character count.** Escaping expands
  each `&`/`<`/`>` to 4–5 bytes. At digest volume (a handful of items per day,
  bounded by the cap) this is negligible, and it is the cost of validity.
- **No semantic upgrade to the body.** This guarantees well-formed XML, not
  semantic XHTML. A body that is already valid markup-free text (the common case
  after the `sources` parser decodes entities) renders unchanged; a body that
  contained stray markup characters now renders as escaped text instead of
  breaking the reader — strictly better. Converting the Lightpanda markdown dump
  to semantic XHTML is a separate, larger concern and is explicitly out of scope
  (Non-Goals).
- **Coupling is unchanged.** The escaper is a private helper inside
  `download.zig`; no new import, no new module, no change to any other capability.
  The `download` capability's boundary (no serving, fetching, scheduling,
  storage mutation, or longevity evaluation) is preserved.
