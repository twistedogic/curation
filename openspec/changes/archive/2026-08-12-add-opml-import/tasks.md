## 1. Reusable scanner/normalization primitives

- [x] 1.1 Promote `extractAttr` to `pub` in `src/feed.zig` (pure, allocation-free
  leaf helper; no behavior change) so the OPML extractor can reuse it for
  `xmlUrl`/`title`/`text` (design D2).
- [x] 1.2 Expose a shared URL-dedupe key (`pub`) built on the existing
  `normalizeUrl` in `src/curation.zig`, so the import merge and the pipeline
  agree on "same source" (design D3). Empty-normalized input is returned as-is,
  not dedupable.
- [x] 1.3 Self-check: the promoted helpers reproduce the pipeline's existing
  normalization outcomes (case-insensitive scheme/host, fragment dropped,
  trailing slash stripped) without regressing `src/curation.zig` tests.

## 2. Pure OPML outline extractor

- [x] 2.1 Add `src/opml.zig` with a pure, I/O-free `extractSources(allocator,
  opml_bytes) -> []config.Source` that scans for `<outline` start tags and, for
  each carrying an `xmlUrl`, builds a `Source` (`url`←`xmlUrl`, `name`←`title`
  else `text` else `url`). Reuses `extractAttr`; introduces no dependency
  (design D2, D6).
- [x] 2.2 Outlines without `xmlUrl` (folders, `htmlUrl`-only) are skipped;
  nested outlines are traversed, not imported (spec: OPML feed-outline
  extraction, Outline field extraction).
- [x] 2.3 Self-check: an OPML 2.0 sample yields its feed leaves in document
  order; nested folders are traversed; a malformed outline is skipped without
  aborting; extraction is deterministic and side-effect free (spec scenarios).
  Mark the substring-scanner ceiling with a `// ponytail:` comment.

## 3. Idempotent merge

- [x] 3.1 Implement `mergeSources(allocator, existing: []const Source, incoming:
  []const Source) -> []Source` that preserves existing order and appends each
  incoming source iff its normalized URL is not already in (existing ∪
  appended), using the shared dedupe key (design D4, spec: Idempotent merge).
- [x] 3.2 Self-check: new sources appended in document order; an already-present
  URL (e.g. `https://EXAMPLE.com/feed#` vs `https://example.com/feed`) is not
  duplicated; re-running on the same OPML is a no-op; empty-normalized URLs are
  kept verbatim and not deduped (spec scenarios).

## 4. Atomic configuration rewrite

- [x] 4.1 Add a config write path in `src/config.zig` that serializes a full
  `Config` to a temporary file in the same directory as the resolved config
  path, then atomically renames it over the path (design D5, spec: Atomic
  configuration rewrite). Only modeled fields are written.
- [x] 4.2 Self-check: a round-trip through `Config.load` → mutate `sources` →
  write → reload yields the merged `sources` with every other field unchanged;
  an interrupted write leaves the original file intact (temp written, rename
  last).

## 5. `curation import` command

- [x] 5.1 Add an `import <opml-file>` branch to the CLI dispatcher in
  `src/server.zig` `run` that: resolves the config path (existing `--config` /
  env / XDG resolution), reads the OPML file, extracts sources, loads the
  config, merges, and writes it back atomically. A missing OPML file is an
  error and mutates nothing (design D1, spec: curation import command).
- [x] 5.2 Self-check: against a temp config dir, `import` of a sample OPML
  rewrites `sources` and preserves other fields; a missing OPML file errors
  without touching the config; the command performs no acquisition (no HTTP,
  no Lightpanda/`pi` spawn, no curation run). The subprocess/acquisition paths
  are not exercised by the suite (consistent with the longevity/sources specs).

## 6. Integration

- [x] 6.1 Register `src/opml.zig` in `main.zig`'s comptime test import block so
  `zig build test` discovers it.
- [x] 6.2 `zig build test` green; `task build` green; `task run -- import
  feeds.opml` exercises the command end-to-end.
