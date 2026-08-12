## 1. XML escaper (download capability)

- [x] 1.1 In `src/download.zig`, add a private helper
  `fn escapeXml(gpa: std.mem.Allocator, s: []const u8) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8`
  that writes `s` into an `std.Io.Writer.Allocating` (the same writer
  `renderOpf`/`renderNav` use), replacing `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`,
  `"`→`&quot;`, `'`→`&#39;` in a single forward pass, scanning each byte and
  writing the replacement (or the byte itself) once. `&` is matched first so an
  input `&` becomes exactly `&amp;` (no double-escape). Returns an owned slice
  (design D2, D3, D4; spec: Well-formed item content documents).
- [x] 1.2 The helper is a pure transform of its input: it performs no I/O beyond
  the in-memory writer, reads no record or store state, and introduces no
  dependency (stdlib only) (design D4; spec: Well-formed item content documents).

## 2. Escape at the emission points (download capability)

- [x] 2.1 In `renderItem`, escape `rec.title` (used twice — in `<head><title>`
  and in `<h1>`) and `rec.body` (in `<p>`) with `escapeXml` before interpolating
  them into the content-document template. The static XHTML markup (`<html>`,
  `<head>`, `<body>`, `<h1>`, `<p>`) is emitted unchanged; only the record text
  is escaped. Free the escaped slices the helper returns (design D1, D2; spec:
  Well-formed item content documents).
- [x] 2.2 In `renderNav`, escape `rec.title` with `escapeXml` in each
  `<li><a href="item{i}.xhtml">{title}</a>` link text. The `href` attribute
  (the index-derived filename) is *not* escaped — it is `item{d}.xhtml`, never
  record text (design D1, D6; spec: Well-formed item content documents).
- [x] 2.3 Leave `renderOpf` untouched. Its `dc:identifier`, `dc:title`, manifest
  `<item>` ids/hrefs, and spine `itemref` idrefs carry only the kind tag and the
  record index — never record text — so they need no escaping (design D6; spec:
  Well-formed item content documents).

## 3. Self-check (download capability)

- [x] 3.1 Extend the existing `zig build test` EPUB self-check (or add a sibling
  test reusing the private `readZipEntries`/`findEntry` helpers) to build an EPUB
  from a single record whose `title` is `A & B < C` and whose `body` is
  `x < y && z > w "q" 'r'`, then assert: the content document's `<head><title>`
  and `<h1>` contain `A &amp; B &lt; C`; its `<p>` contains `x &lt; y &amp;&amp;
  z &gt; w &quot;q&quot; &#39;r&#39;`; and no bare `&` or `<` from the record is
  present in the document (design D3, D5; spec: Well-formed item content
  documents).
- [x] 3.2 In the same self-check, assert the navigation document's `<a>` link
  text is `A &amp; B &lt; C` (escaped) and that the `href="item1.xhtml"`
  attribute is unchanged (design D2, D6; spec: Well-formed item content
  documents).
- [x] 3.3 Assert markup-free text is emitted verbatim: building an EPUB from a
  record whose `title` is `Alpha` and `body` is `first` yields a content document
  whose text is `Alpha` / `first` with no `&amp;`/`&lt;` introduced, so escaping
  is a no-op on markup-free content (design D2; spec: Well-formed item content
  documents).
- [x] 3.4 Assert the existing structural self-check still passes (mimetype first
  and stored, `container.xml` points at the OPF, the OPF manifest references the
  nav and every content document) — escaping changes only document text, not the
  container, so no regression (design D6; spec: EPUB structural validity).

## 4. Integration

- [x] 4.1 No new module to register (`download.zig` is already imported by
  `server.zig` and registered in `main.zig`'s comptime test block); no route,
  status code, `X-Next-Token`, auth-ordering, token, store, config, or record
  format change.
- [x] 4.2 `zig build test` green; `openspec validate fix-epub-xhtml-escaping`
  passes; `openspec validate --all` stays green (9 capabilities).
