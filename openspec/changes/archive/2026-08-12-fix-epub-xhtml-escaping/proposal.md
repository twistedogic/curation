## Why

Intent **G4** requires "a valid EPUB (passes `epubcheck`-equivalent structural
checks) that renders on common e-readers," and §8 lists "a generated EPUB opens
on at least one real e-reader without errors" as a success metric. The
`download` capability's EPUB builder satisfies the *container* half of that
(`mimetype` stored first and uncompressed, `META-INF/container.xml`, an OPF
manifest, a navigation document, a structural self-check) — but it fails the
*content* half on the common case. `renderItem` and `renderNav` interpolate each
record's `title` and `body` into XHTML with a bare `{s}`, and the `sources`
capability's tolerant parser explicitly *decodes* XML entities and *unwraps*
`<![CDATA[…]]>` sections before the text ever reaches the store. So fetched text
arrives at the builder with literal `&`, `<`, `>`, `"`, `'`. A feed item titled
`A & B < C`, or any body containing `<`, `&`, or a comparison like `x < y`,
produces `<h1>A & B < C</h1>` — malformed XHTML. The structural self-check never
looks inside a content document, so it stays green while the EPUB an e-reader
(or `epubcheck`) opens is not well-formed XML.

This is the one remaining correctness defect in the acquire → curate → classify
→ store → serve data path: every other XML/JSON boundary is already handled
correctly (`std.json` escapes the JSONL store; `pi` takes raw text on stdin; the
UI is a static page with no server-side templating). The EPUB's emitted XHTML is
the only place record text is written into a markup context, and it is the only
one that does not escape. It is reproduced before the fix (a record with `<`/`&`
yields bare markup in the document) and carries a regression test, exactly the
discipline `AGENTS.md` requires of a bug fix.

This change is the smallest one that closes it: XML-escape record `title` and
`body` at the two emission points that already exist (`renderItem`,
`renderNav`), and extend the existing `zig build test` EPUB self-check to build
an EPUB from a hostile record and assert the escaping — so the malformed-XHTML
path fails the build if it ever returns. No new capability, no new dependency, no
store, config, route, token, or container-structure change. `zig build test`
stays green.

## What Changes

- Modify the **`download` capability** so the EPUB builder XML-escapes each
  record's `title` and `body` wherever it emits them into the EPUB: in each
  item's XHTML content document (the `<head><title>`, the `<h1>` heading, and the
  `<p>` body) and in the navigation document's table-of-contents link text.
  Escaping replaces `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `"`→`&quot;`,
  `'`→`&#39;`, applied to the record text only and never to the static XHTML the
  builder emits; `&` is replaced first so an input `&` is not double-escaped.
- Extend the existing `zig build test` EPUB self-check in `src/download.zig` to
  build an EPUB from a record whose `title`/`body` contain `<`, `&`, `>`, `"`,
  `'`, and assert that the emitted content document and the navigation link text
  escape them (the build fails if a bare `&` or `<` from the record reaches
  either document). This reuses the private `readZipEntries`/`findEntry` helpers
  the existing structural self-check already uses; no new test harness.
- Leave untouched the OPF package (its `dc:identifier`, `dc:title`, manifest, and
  spine carry only the kind tag and index-derived item ids — never record text,
  so they need no escaping), the token codec, the ZIP writer, the incremental
  resolver, and the observability recorder.
- Standard library only (`std.mem` scanning for the five characters); `zig build
  test` stays green. No new dependency; stays a single binary.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `download`: a new "Well-formed item content documents" requirement — the EPUB
  builder SHALL XML-escape each record's `title` and `body` in the item XHTML
  content documents (`<head><title>`, `<h1>`, `<p>`) and in the navigation
  document's link text, so records containing `&`, `<`, `>`, `"`, or `'` still
  yield well-formed XHTML; the `zig build test` self-check is extended to assert
  it. The token codec, the OPF package, the ZIP container structure, the
  kind-parametric builder contract, the incremental resolver and its half-open
  `(token.id, …]` range, the capability boundary, and the EPUB-generation
  observability requirement are unchanged.

## Impact

- **Code:** `src/download.zig` gains one small `escapeXml` helper (standard
  library only) and calls it in `renderItem` (escaping the record `title` at both
  its `<head><title>` and `<h1>` occurrences and the `body` at its `<p>`
  occurrence) and in `renderNav` (escaping the record `title` in each `<a>` link
  text); the existing `zig build test` EPUB self-check is extended with a
  hostile-record case. `renderOpf`, the token codec, the ZIP writer, and the
  resolver are consumed unchanged. No other `.zig` file changes.
- **APIs:** no HTTP route or status change. `GET /download` returns the same
  `200 application/epub+zip` (or `204`/`400`/`401`), `X-Next-Token`, and
  content-type; the EPUB it streams is now well-formed XHTML inside. No endpoint
  contract changes. The `build`/`resolve` signatures are unchanged.
- **Dependencies:** none added — Zig 0.16 standard library only. Stays a single
  binary; no external runtime dependency.
- **Data:** no store, config, eval-cache, token, or record-format change. Record
  text is stored raw exactly as today (the `sources` parser still decodes
  entities/CDATA); only the EPUB emission escapes it. The JSONL store (escaped by
  `std.json`) and the longevity cache are untouched.
- **Automation:** no `Taskfile.yml` or CI change; `task test` covers the extended
  self-check (a hostile record's `<`/`&`/`>`/`"`/`'` are escaped in the content
  document and the nav link text; markup-free text is emitted verbatim; the build
  fails if a bare `&` or `<` from a record reaches either document).
- **Scope note:** this closes the last correctness gap in intent G4's data path
  — every record, however markup-laden its title or body, now produces a
  well-formed EPUB that opens on an e-reader.
