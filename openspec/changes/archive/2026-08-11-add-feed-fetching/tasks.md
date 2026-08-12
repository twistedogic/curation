## 1. Feed parser core

- [x] 1.1 Add `src/feed.zig` with `parseFeed(allocator, bytes: []const u8,
  source: []const u8) ![]Item` detecting RSS vs Atom by root element
  (`<rss`/`<rdf:RDF` ⇒ RSS `<item>`; `<feed` ⇒ Atom `<entry>`), returning items
  in document order (design D1, D4).
- [x] 1.2 Self-check: an embedded RSS 2.0 feed with two `<item>` blocks yields
  two items whose `title`/`url`/`body`/`date` come from the elements and whose
  `source` is the supplied name (spec: Feed item extraction).

## 2. Atom support

- [x] 2.1 Extend `parseFeed` to extract Atom `<entry>` blocks: `url` from
  `<link href="…">`, `body` from `<summary>`/`<content>`, `date` from
  `<updated>`/`<published>` (design D4).
- [x] 2.2 Self-check: an embedded Atom feed yields one item with url/body/date
  from the entry elements (spec: Feed item extraction).

## 3. Tolerant field extraction

- [x] 3.1 Implement XML entity decoding (named `&amp; &lt; &gt; &quot; &apos;`
  plus numeric `&#NN;`/`&#xHH;`), `<![CDATA[…]]>` unwrapping, and whitespace
  trimming on title/url (design D3).
- [x] 3.2 Implement missing-field → empty-string defaults and per-field skip on
  malformed elements so the parse of remaining items continues.
- [x] 3.3 Self-check: `<![CDATA[ A &amp; B ]]>` decodes to `A & B`; an item with
  a title but no `<link>` has an empty `url`; a malformed element in one item
  does not abort extraction of the next (spec: Tolerant field extraction).

## 4. Purity and determinism

- [x] 4.1 Confirm `parseFeed` performs no network/filesystem/subprocess I/O and
  is deterministic: identical bytes + source yield equal items in equal order
  across two runs (design D2).
- [x] 4.2 Self-check: run `parseFeed` twice on the same bytes and assert the
  results are field-for-field equal and in the same order (spec: Feed item
  extraction).

## 5. Feed fetcher

- [x] 5.1 Add `src/fetch.zig` with
  `fetchFeed(allocator, client, url, user_agent, timeout) ![]u8` using
  `std.http.Client`, sending `User-Agent`, bounded by the timeout; return body
  bytes on 2xx, an error otherwise (FR-3, design D2).
- [x] 5.2 Self-check: an error path (e.g., an unresolvable/invalid URL) returns
  an error without crashing (spec: Feed fetching over HTTP).

## 6. Per-source acquisition

- [x] 6.1 Implement `acquireFeed(allocator, client, source_url, source_name,
  user_agent, timeout) ![]Item` composing `fetchFeed` → `parseFeed`, returning
  items or an error per source (design D5).
- [x] 6.2 Self-check (purity/isolation): a failing fetch/parse path returns an
  error; a successful path returns its items — verified without live network by
  exercising the parse path and the fetch error path separately (spec:
  Per-source error isolation).

## 7. Integration

- [x] 7.1 Register `src/fetch.zig` and `src/feed.zig` in `main.zig`'s comptime
  test-import block so `zig build test` discovers them.
- [x] 7.2 `zig build test` green.
