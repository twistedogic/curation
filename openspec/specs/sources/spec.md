# sources Specification

## Purpose
The acquisition of item records from configured sources — fetching an
RSS/Atom feed over HTTP and extracting item records via a tolerant XML
parser. The fetched items flow unchanged into the `curation` pipeline. Web
content sources (rendered out-of-process via Lightpanda) are added in a
later change.

This capability owns only the fetch + parse boundary. Reading configured
source URLs, scheduling, and per-source logging live in the daily-job
change; storage and longevity evaluation live in their own changes.
## Requirements
### Requirement: Feed fetching over HTTP

The system SHALL fetch a feed source over HTTP using `std.http.Client`, sending
a `User-Agent` header and enforcing a bounded connect and read timeout. A fetch
SHALL return the response body bytes on a 2xx response. A network error, a
non-2xx status, a timeout, or a failure to read the body SHALL be reported as an
error to the caller and SHALL NOT terminate the process. The fetcher SHALL
perform no parsing of the body.

#### Scenario: a 2xx response yields the body bytes

- **WHEN** the fetcher requests a URL whose server returns `200` with a feed
  body
- **THEN** it returns those body bytes

#### Scenario: a non-2xx status is reported as an error

- **WHEN** the fetcher requests a URL whose server returns `404`
- **THEN** it returns an error and no bytes, without terminating the process

#### Scenario: an unreachable host is reported as an error

- **WHEN** the fetcher requests a URL whose host cannot be reached or resolved
- **THEN** it returns an error within the configured timeout, without
  terminating the process

### Requirement: Feed item extraction

The system SHALL extract item records from fetched feed bytes through a pure,
I/O-free parser that accepts both Really Simple Syndication (RSS) feeds
(RSS 2.0 and RDF Site Summary) and Atom feeds. Each extracted item SHALL carry
the fields `title`, `url`, `body`, `date`, and `source`, matching the
`curation` capability's item model. The parser SHALL be deterministic: given
identical feed bytes and source name, it SHALL produce equal items in equal
order on every run, independent of wall-clock time or host. The parser SHALL
perform no network, filesystem, or subprocess I/O.

#### Scenario: an RSS 2.0 feed yields items

- **WHEN** the parser processes an RSS 2.0 document with two `<item>` blocks
  each having title, link, description, and pubDate
- **THEN** it returns two items whose `title`, `url`, `body`, and `date` come
  from those elements and whose `source` is the supplied source name

#### Scenario: an Atom feed yields items

- **WHEN** the parser processes an Atom document with one `<entry>` block
  having title, a `<link href>`, a summary, and an updated date
- **THEN** it returns one item whose `url` comes from the `<link>` `href`, whose
  `body` comes from the summary, and whose `date` comes from the updated date

#### Scenario: parsing is deterministic

- **WHEN** the parser runs twice on the same feed bytes and source name
- **THEN** both runs return items that are equal field-for-field and in the same
  order

#### Scenario: parsing is pure of side effects

- **WHEN** the parser runs
- **THEN** it performs no reads from or writes to the network, the filesystem,
  or any child process

### Requirement: Tolerant field extraction

For each item the parser SHALL extract `title` from a `<title>` element; `url`
from an RSS `<link>` element's text or an Atom `<link>` element's `href`
attribute; `body` from an RSS `<description>` element or an Atom `<summary>` or
`<content>` element; and `date` from an RSS `<pubDate>` element or an Atom
`<updated>` or `<published>` element. It SHALL decode XML character entities
(`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, and numeric character
references), SHALL unwrap `<![CDATA[…]]>` sections, and SHALL trim surrounding
whitespace on `title` and `url`. An item missing a field SHALL default that
field to the empty string, so that an empty `url` remains a valid item per the
`curation` capability. An element that is present but malformed SHALL be skipped
for that field without aborting the parse of the remaining items.

#### Scenario: entities and CDATA are decoded

- **WHEN** an item's description is `<![CDATA[ A &amp; B ]]>`
- **THEN** the item's `body` is `A & B`

#### Scenario: a missing link yields an empty url

- **WHEN** an RSS `<item>` has a title but no `<link>`
- **THEN** the item's `url` is the empty string and the item is otherwise valid

#### Scenario: a malformed element does not abort the parse

- **WHEN** a feed contains one item with a malformed `<pubDate>` followed by a
  well-formed item
- **THEN** the well-formed item is still extracted, and the malformed field
  defaults to empty

### Requirement: Per-source error isolation

The system SHALL provide an acquisition step that, for a single source, performs
the fetch and the extraction and returns the extracted items, or an error if
either step fails. A failure for one source SHALL be reportable to the caller as
an error without the caller observing partial items, so that a caller iterating
multiple sources MAY skip and log the failing source and continue with the
others. No failure of a single source's fetch or parse SHALL abort a
multi-source run handled by the caller.

#### Scenario: a failing source returns an error, not a crash

- **WHEN** acquisition is attempted for a source whose fetch or parse fails
- **THEN** it returns an error and the process continues, so the caller can move
  to the next source

#### Scenario: a successful source returns its items

- **WHEN** acquisition is attempted for a source whose fetch and parse succeed
  with two items
- **THEN** it returns those two items

### Requirement: Web-content acquisition via Lightpanda

The system SHALL acquire a web-content source by rendering it out-of-process
through the Lightpanda headless browser, invoking
`<lightpanda.path> fetch --dump <lightpanda.dump_format> <source.url>` as a
child process (argv built as discrete elements — never a shell string — so the
URL cannot inject flags or commands) and capturing its standard output. The
captured output SHALL become the item `body` verbatim; the item `url` SHALL be
the source URL; and `title` and `source` SHALL be the source name. The
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

