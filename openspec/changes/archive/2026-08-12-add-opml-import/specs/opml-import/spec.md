# opml-import Specification

## Purpose
The one-shot configuration mutation that reads an Outline Processor Markup
Language (OPML) file and merges its feed outlines into the configuration's
feed `sources`. It owns OPML outline extraction, the idempotent merge, and the
atomic rewrite of the configuration file. It performs no acquisition, no
serving, no scheduling, and no item storage; those live in their respective
capabilities. This is the only configured input path the PRD left
unautomated (intent §9 Decision #6).

## Requirements
## ADDED Requirements

### Requirement: OPML feed-outline extraction

The system SHALL provide a pure, I/O-free function that scans Outline Processor
Markup Language (OPML) bytes and returns a list of feed sources
(`[]config.Source`, each a `name` and `url`). Only `<outline>` elements that
carry an `xmlUrl` attribute SHALL contribute a source; its `url` SHALL be the
`xmlUrl` attribute value. The extractor SHALL perform no network, filesystem,
or subprocess I/O, and SHALL reuse the tolerant attribute scanner already used
by the feed parser (it SHALL NOT introduce a new XML or OPML dependency). The
extraction SHALL be deterministic: identical OPML bytes SHALL yield equal
sources in equal order on every run.

#### Scenario: an OPML 2.0 file yields its feed outlines

- **WHEN** the extractor processes an OPML 2.0 document whose `<body>` contains
  two `<outline xmlUrl="…" title="…"/>` elements
- **THEN** it returns two sources whose `url` is each outline's `xmlUrl` and
  whose `name` is each outline's `title`

#### Scenario: nested folders are traversed, not imported

- **WHEN** the extractor processes an OPML document with folder `<outline>`
  elements (no `xmlUrl`) that nest further `<outline xmlUrl="…"/>` feed leaves
- **THEN** only the feed-leaf outlines are returned, in document order, and the
  folder outlines contribute no source

#### Scenario: an outline without xmlUrl is skipped

- **WHEN** the extractor processes an OPML document containing an
  `<outline htmlUrl="…" title="…"/>` element with no `xmlUrl`
- **THEN** that outline contributes no source and the run continues

#### Scenario: extraction is pure of side effects

- **WHEN** the extractor runs
- **THEN** it performs no reads from or writes to the network, the filesystem,
  or any child process

#### Scenario: extraction is deterministic

- **WHEN** the extractor runs twice on the same OPML bytes
- **THEN** both runs return sources that are equal field-for-field and in the
  same order

### Requirement: Outline field extraction

For each `xmlUrl`-bearing outline the extractor SHALL set the source `url` to
the `xmlUrl` attribute value. It SHALL set the source `name` to the outline's
`title` attribute value, or, when `title` is absent, the `text` attribute value,
or, when both are absent, the `url` itself, so a source is never nameless. The
extractor SHALL be tolerant: an outline whose attributes cannot be parsed SHALL
be skipped without aborting the extraction of the remaining outlines.

#### Scenario: name comes from title when present

- **WHEN** an outline has both `title="A"` and `text="B"`
- **THEN** the source's `name` is `A`

#### Scenario: name falls back to text when title is absent

- **WHEN** an outline has `text="B"` and no `title`
- **THEN** the source's `name` is `B`

#### Scenario: name falls back to the url when neither title nor text is present

- **WHEN** an outline has only `xmlUrl="https://example/feed"`
- **THEN** the source's `name` is `https://example/feed`

#### Scenario: a malformed outline does not abort the extraction

- **WHEN** the document contains one outline with an unparseable tag followed by
  a well-formed feed outline
- **THEN** the well-formed outline is still extracted

### Requirement: Idempotent merge into configuration sources

The system SHALL merge the extracted sources into the configuration's existing
feed `sources`. Existing sources SHALL be preserved in place and order. An
extracted source SHALL be appended iff its normalized URL is not already present
among the existing sources or the sources already appended in this merge, using
the same URL normalization the curation pipeline applies for item dedupe
(lowercase scheme and host, drop the fragment, strip the trailing slash). An
extracted source whose URL normalizes to empty SHALL be appended verbatim and
SHALL NOT be deduped. Re-running the import on the same OPML SHALL leave the
`sources` array unchanged.

#### Scenario: new sources are appended in document order

- **WHEN** the configuration has no sources and the OPML contributes two new
  feed outlines
- **THEN** both are appended in document order

#### Scenario: an already-present source is not duplicated

- **WHEN** the configuration already lists a source with URL
  `https://example.com/feed` and the OPML contributes `https://EXAMPLE.com/feed#`
- **THEN** no duplicate is appended, because the two normalize equal

#### Scenario: re-importing the same OPML is a no-op

- **WHEN** the import is run twice on the same OPML against the same
  configuration
- **THEN** the `sources` array after the second run equals the array after the
  first run

#### Scenario: existing source order and identity are preserved

- **WHEN** the configuration lists sources `[S1, S2]` and the OPML contributes
  one new source `S3`
- **THEN** the merged array is `[S1, S2, S3]` with `S1` and `S2` unchanged

### Requirement: curation import command

The system SHALL provide a `curation import <opml-file>` command that reads the
named OPML file, extracts its feed outlines, merges them into the configuration
loaded from the resolved configuration path (the same XDG / `--config` /
environment path the `serve` command uses), and writes the merged configuration
back to that path. A missing OPML file SHALL be reported as an error without
mutating the configuration. The command SHALL perform no feed fetching, no
rendering, no longevity evaluation, no HTTP serving, and no scheduling; it is a
one-shot configuration mutation that completes before returning.

#### Scenario: import merges feeds and writes the configuration

- **WHEN** `curation import feeds.opml` is run against a configuration with one
  existing source, and `feeds.opml` contributes two new feed outlines
- **THEN** the configuration file on the resolved path is rewritten so its
  `sources` array contains the existing source followed by the two new ones, and
  every other configuration field is unchanged

#### Scenario: a missing OPML file is an error and mutates nothing

- **WHEN** `curation import missing.opml` is run and `missing.opml` does not
  exist
- **THEN** the command reports an error and the configuration file is not
  modified

#### Scenario: the import command performs no acquisition

- **WHEN** the import command runs
- **THEN** it issues no HTTP request, spawns no Lightpanda or `pi` child
  process, and starts no curation run

### Requirement: Atomic configuration rewrite

The merged configuration SHALL be written by serializing the full in-memory
configuration to a temporary file in the same directory as the resolved
configuration path and then atomically renaming the temporary file over the
resolved path. An interrupted write SHALL leave the pre-import configuration
file intact. Only the `sources` array SHALL differ from the pre-import file;
every other field SHALL be preserved.

#### Scenario: the rewrite is atomic via a sibling temporary file

- **WHEN** the merged configuration is written
- **THEN** a temporary file is created in the same directory as the
  configuration path and is atomically renamed over it, so no reader ever
  observes a partially written configuration

#### Scenario: only the sources field changes

- **WHEN** the configuration is rewritten after an import
- **THEN** the new file equals the old file except that its `sources` array
  contains the merged set, and all other modeled fields are unchanged

### Requirement: Capability boundary

The OPML-import capability SHALL own only OPML outline extraction, the
idempotent merge into configuration feed `sources`, and the atomic rewrite of
the configuration file. It SHALL own no feed fetching or parsing, no web
rendering, no longevity evaluation, no HTTP serving, no scheduling, and no item
storage; those live in their respective capabilities. The extractor SHALL be
invokable as a pure library function independent of the command and the
filesystem.

#### Scenario: the extractor is invokable as a library

- **WHEN** the extractor function is called directly with OPML bytes
- **THEN** it returns the extracted sources without any command, file, or
  network access

#### Scenario: import owns no acquisition, serving, or storage

- **WHEN** the import command runs
- **THEN** it reads only the named OPML file and the configuration file, writes
  only the configuration file, and delegates nothing to the fetcher, the
  renderer, the longevity evaluator, the HTTP server, the scheduler, or the
  store
