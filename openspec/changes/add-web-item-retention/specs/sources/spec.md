## MODIFIED Requirements

### Requirement: Web-content acquisition via Lightpanda

The system SHALL acquire a web-content source by rendering it out-of-process
through the Lightpanda headless browser, invoking
`<lightpanda.path> fetch --dump <lightpanda.dump_format> <source.url>` as a
child process (argv built as discrete elements — never a shell string — so the
URL cannot inject flags or commands) and capturing its standard output. The
captured output SHALL become the item `body` verbatim; the item `url` SHALL be
the source URL; and `title` and `source` SHALL be the source name. The item
`date` SHALL be the acquisition instant — the renderer's wall-clock time at the
moment of capture — formatted as ISO-8601 Coordinated Universal Time (UTC)
(e.g. `2026-08-13T04:00:00Z`), so the storage capability's age-based retention
prune covers web-content items identically to feed items; the `date` is the
capture instant, not a publish date parsed from the rendered page. The
acquisition SHALL return exactly one item per web source. A failure to start
the child process (the configured binary cannot be found or started), a non-zero
exit, a timeout, or an empty captured output SHALL be reported as an error to
the caller and SHALL NOT terminate the process. The acquisition SHALL perform
no HyperText Transfer Protocol (HTTP) request of its own (Lightpanda performs
the fetch) and SHALL perform no feed parsing; the rendered output is the
extracted body, with no separate readability step.

#### Scenario: a successful render yields one item whose body is the captured output

- **WHEN** the renderer is given a web source whose Lightpanda invocation exits
  zero and prints a markdown body
- **THEN** it returns exactly one item whose `body` is that captured output
  verbatim, whose `url` is the source URL, and whose `title` and `source` are
  the source name

#### Scenario: a successful render stamps an ISO-8601 acquisition date

- **WHEN** the renderer is given a web source whose Lightpanda invocation exits
  zero and prints a non-empty body
- **THEN** the returned item's `date` is non-empty, matches the ISO-8601 UTC
  shape (`YYYY-MM-DDTHH:MM:SSZ`), and is a value the storage capability's
  date parser accepts, so a web-content item older than the retention window is
  pruned exactly like a dated feed item

#### Scenario: a missing binary is reported as an error, not a crash

- **WHEN** the renderer is given a source whose configured Lightpanda path
  cannot be found or started
- **THEN** it returns an error and no items, without terminating the process

#### Scenario: a non-zero exit is reported as an error

- **WHEN** the Lightpanda invocation exits non-zero
- **THEN** it returns an error and no items, without terminating the process

#### Scenario: an empty captured output is reported as an error

- **WHEN** the Lightpanda invocation exits zero but prints nothing
- **THEN** it returns an error and no items

#### Scenario: the renderer performs no HTTP or feed parsing of its own

- **WHEN** the renderer runs
- **THEN** it issues no HTTP request from curation and parses no feed; it
  delegates the fetch to Lightpanda and treats stdout as the body verbatim
