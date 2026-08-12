## MODIFIED Requirements

### Requirement: One curation run

The system SHALL provide a synchronous curation run that, given a list of feed
sources, a list of web-content sources, a Lightpanda configuration, the curation
rules, a `pi` longevity configuration, an HTTP client, an evaluation cache, a
`pi` invoker, a store, and a log writer, performs exactly one end-to-end pass:
it SHALL acquire each configured feed source (fetch and parse) via the `sources`
capability; it SHALL acquire each configured web-content source (render via the
Lightpanda headless browser) via the `sources` capability; it SHALL gather all
extracted items across both kinds of sources; it SHALL run the `curation`
capability's pure pipeline (dedupe, filter, tag, cap) over the union; for each
surviving curated item it SHALL classify its longevity via the `longevity`
capability to obtain a stream `Kind`; and it SHALL append each survivor to the
store via the `storage` capability under that `Kind`. The run SHALL return a
summary carrying at least the number of sources seen (feed sources plus
web-content sources), the number of items fetched, the number of curated
survivors, the number of items stored per `Kind` (`news`, `knowledge`), and the
number of sources that failed. The run SHALL treat a web-content item no
differently from a feed item once acquired — both flow through the same pipeline,
classification, and storage. The run SHALL perform no longevity evaluation of
its own (it obtains the `Kind` solely from the `longevity` capability) and SHALL
perform no HTTP serving, no daily scheduling, and no token encoding or EPUB
generation.

#### Scenario: a run stores each survivor under its classified kind

- **WHEN** a run is given two feed sources whose items, after the pipeline, leave
  three survivors, and the longevity classifier returns `news` for two and
  `knowledge` for one
- **THEN** the store gains exactly three records — two of `kind` `news` and one
  of `kind` `knowledge` — and the returned summary reports `news = 2` and
  `knowledge = 1`

#### Scenario: a run acquires web sources alongside feed sources

- **WHEN** a run is given one feed source (yielding one item) and one web-content
  source (yielding one item), both surviving the pipeline, and the longevity
  classifier returns `knowledge` for both
- **THEN** the store gains two records of `kind` `knowledge`, the returned
  summary reports `sources = 2` and `knowledge = 2`, and both items are stored
  under the same kind regardless of which source kind produced them

#### Scenario: a run passes the configured cap to the pipeline

- **WHEN** a run is given a configuration whose per-run `cap` is `2` and five
  items would otherwise survive
- **THEN** the pipeline returns at most two survivors and the store gains at most
  two records

#### Scenario: an empty source list stores nothing

- **WHEN** a run is given no feed sources and no web-content sources
- **THEN** it fetches and renders nothing, classifies nothing, appends nothing,
  and returns a summary whose counts are all zero

### Requirement: Per-source error isolation

The system SHALL isolate each source's acquisition so that a network error, a
non-2xx status, a timeout, a parse failure, or a web-content render failure (a
missing Lightpanda binary, a non-zero exit, a render timeout, or an empty
captured output) for one source SHALL be reported as a failure of that source
only: the run SHALL log it, count it in the summary's failed-sources count, and
continue acquiring the remaining sources. A failing source SHALL NOT cause the
run to observe partial items from that source, and SHALL NOT abort the run or the
storage of survivors from other sources. A `pi` classification failure is NOT a
source failure (it is absorbed by the `longevity` capability's fallback) and
SHALL NOT be counted as a failed source.

#### Scenario: a failing source is skipped and the run continues

- **WHEN** a run is given three sources of which the second fails to fetch and
  the other two each yield survivors
- **THEN** the run stores the survivors of the first and third sources, the
  summary's failed-sources count is `1`, and the run does not abort

#### Scenario: a failing web source is skipped and the run continues

- **WHEN** a run is given one feed source (yielding a survivor) and one
  web-content source whose render fails (the Lightpanda binary is missing)
- **THEN** the run stores the feed source's survivor, the summary's
  failed-sources count is `1`, and the run does not abort

#### Scenario: a parse failure for one source does not lose another's items

- **WHEN** a run is given two sources and the first yields a feed that fails to
  parse while the second yields two survivors
- **THEN** the store gains the two survivors from the second source and the
  summary's failed-sources count is `1`

#### Scenario: a pi failure is not counted as a failed source

- **WHEN** a survivor's `pi` classification fails (so the `longevity` capability
  returns its fallback `Kind`) during a run whose every source fetched and parsed
- **THEN** the summary's failed-sources count is `0` and the survivor is still
  stored under the fallback `Kind`
