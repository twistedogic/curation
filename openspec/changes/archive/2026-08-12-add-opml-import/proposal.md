## Why

The PRD (`.see/intent.md` §6 Non-Goals and §9 Decision #6) ships RSS/Atom feed
curation but explicitly defers a follow-up: "OPML import = yes, as a follow-up
story. Cheap — reuses the XML tokenizer built for RSS/Atom. Add a `curation
import <opml>` command." Every other v1 user story (US-001 … US-009) already has
a capability and an archived change; OPML import is the named gap. Operators
today must hand-edit `config.json` to add feed sources one by one, which is the
one configured-but-unautomated input path the PRD calls out. This change closes
that gap with a small, self-contained command that reuses the existing tolerant
XML scanner (`src/feed.zig`) and the existing `Source`/`Config` model.

## What Changes

- Add a `curation import <opml-file>` command: read an Outline Processor Markup
  Language (OPML) file, extract its feed outlines, merge them into the
  configuration's feed `sources`, and write the updated configuration back to
  the resolved config path (the same XDG/`--config`/env path `serve` uses).
- Add a pure, I/O-free OPML outline extractor that scans OPML bytes and yields
  `[]config.Source` records (name from the `title`/`text` attribute, url from
  `xmlUrl`). It reuses the tolerant tag/attribute scanning already present in
  `src/feed.zig`; no new XML dependency is introduced.
- Only outlines carrying an `xmlUrl` attribute are feed sources; structural
  outlines (folders/categories, `htmlUrl`-only links) are skipped, so nested
  OPML trees are traversed rather than imported literally.
- The merge is idempotent: a source already present by url (after the same
  normalization the curation pipeline uses) is not duplicated; new sources are
  appended in document order.
- The configuration is rewritten with the merged `sources` via an atomic
  write (temporary file in the same directory, then rename), leaving every other
  configuration field untouched.
- No dependency is added; everything runs through `zig build` / `zig build test`
  (stdlib-only, per intent §2).

## Capabilities

### New Capabilities
- `opml-import`: A `curation import <opml-file>` command and the pure OPML
  outline extractor behind it. Owns reading an OPML file, extracting feed
  outlines into `[]config.Source`, merging them idempotently into the
  configuration's feed `sources`, and writing the configuration back
  atomically. This is the only configured input path the PRD left unautomated
  (intent §9 Decision #6).

### Modified Capabilities
<!-- None. The new subcommand is dispatched alongside `serve` in the CLI entry,
but that wiring is implementation detail; the `server` capability's specified
requirements (lifecycle, config loading, healthz, auth, metrics, download, UI,
curate, scheduler) are unchanged. -->

## Impact

- **Code:** a new `src/opml.zig` module (pure extractor + tests), a new `import`
  subcommand branch in the CLI dispatcher (`src/server.zig` `run`), and a
  configuration write path (atomic temp+rename) likely living in
  `src/config.zig`. No existing behavior changes for `serve` or the curation
  pipeline.
- **Config:** reads and rewrites the existing JSON config file
  (`$XDG_CONFIG_HOME/curation/config.json`, overridable via `--config` / env);
  only the `sources` array grows. No schema change — `Source` (`name` + `url`)
  already models an OPML feed outline.
- **Dependencies:** none added — Zig 0.16 stdlib only; reuses the existing
  tolerant scanner in `src/feed.zig`.
- **Automation:** `Taskfile.yml` already provides `build`/`test`/`run`; `task
  run -- import feeds.opml` exercises the new command. No CI changes beyond
  what Task already drives.
