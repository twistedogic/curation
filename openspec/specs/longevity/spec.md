# longevity Specification

## Purpose
The pi-based longevity evaluator — the only non-deterministic stage of the
curation pipeline. Given a curated item's title and body, it produces a
stream kind (`news`/`knowledge`) by wrapping the local `pi` agent CLI,
caching successful classifications on SHA-256(title+body), and degrading to a
configured-default kind on any failure. curation holds no provider, model, or
API-key configuration; `pi` owns all credentials and routing. The evaluator
owns the label-to-kind mapping, the strict `pi`-result parser, the evaluation
cache, and the evaluation configuration; it performs no HTTP serving, no
daily scheduling, and no item storage.
## Requirements
### Requirement: Label-to-kind mapping

The system SHALL model an item's longevity as a `Label` of `short_term`,
`long_term`, or `unknown`, and SHALL map it to exactly one stream `Kind`:
`short_term` → `news`, `long_term` → `knowledge`, and `unknown` → the
configured default kind (default `news`). An item SHALL be placed in exactly
one kind.

#### Scenario: short_term routes to news

- **WHEN** a surviving item is classified `short_term`
- **THEN** its kind is `news`

#### Scenario: long_term routes to knowledge

- **WHEN** a surviving item is classified `long_term`
- **THEN** its kind is `knowledge`

#### Scenario: unknown falls back to the configured default kind

- **WHEN** an item is classified `unknown` and the configured default kind is
  `news`
- **THEN** its kind is `news`

### Requirement: Longevity classification

The system SHALL provide a longevity evaluator that, for a given curated item
(title + body), classifies it into a stream `Kind` by: computing the cache key;
consulting the evaluation cache; on a miss, rendering the configured
classification prompt with the item's title and body and invoking `pi`
out-of-process; parsing the result; writing the cache on success; and applying
the label-to-kind mapping. curation SHALL hold no provider, model, or API-key
configuration — all model access goes through `pi`, which owns credentials and
routing. The evaluator SHALL be invokable as a library and SHALL perform no
HTTP serving, scheduling, or item storage in this capability.

#### Scenario: a classified item returns a kind

- **WHEN** the evaluator classifies an item whose title+body `pi` answers
  `long_term`
- **THEN** it returns kind `knowledge`

#### Scenario: curation holds no provider credentials

- **WHEN** the evaluator is configured
- **THEN** the configuration contains no provider, model-API-key, or base-URL
  field; only `pi` invocation parameters

#### Scenario: the evaluator owns no serving or scheduling

- **WHEN** the evaluator runs
- **THEN** it performs no HTTP serving, no daily scheduling, and no item
  storage

### Requirement: Strict label parsing

The system SHALL parse the `pi` result for the tokens `short_term` and
`long_term` case-insensitively at a token boundary, accepting the first valid
token. Any result that is empty, contains no valid token, or is otherwise
unparseable SHALL yield the label `unknown`. The parser SHALL NOT guess an
approximate label.

#### Scenario: case-insensitive tokens are accepted

- **WHEN** pi stdout is `LONG_TERM`
- **THEN** the parsed label is `long_term`

#### Scenario: an unparseable result is unknown

- **WHEN** pi stdout is the prose sentence `I think this is probably news`
- **THEN** the parsed label is `unknown`

#### Scenario: a hyphenated variant is unknown

- **WHEN** pi stdout is `short-term`
- **THEN** the parsed label is `unknown`

#### Scenario: an empty result is unknown

- **WHEN** pi stdout is empty
- **THEN** the parsed label is `unknown`

### Requirement: Failure tolerance

The system SHALL treat any evaluation failure — `pi` not found, a non-zero
exit, a timeout, or an unparseable result — as the label `unknown`, which maps
to the configured default kind. A failure SHALL be logged and SHALL NOT abort
the evaluation of other items or the enclosing run. The evaluator SHALL return
the fallback kind rather than an error to its caller. A `pi` invocation that
does not terminate within the configured `timeout_seconds` SHALL be bounded by
that timeout: once it elapses the child process SHALL be killed and the failed
evaluation SHALL be reported as `unknown` and routed to the default kind, so a
single wedged classification SHALL never stall the evaluation of remaining items
or the enclosing run.

#### Scenario: a missing pi binary falls back

- **WHEN** the configured `pi` binary cannot be started
- **THEN** the item is labeled `unknown`, routed to the default kind, and
  logged, and evaluation continues

#### Scenario: a non-zero exit falls back

- **WHEN** the pi invocation exits non-zero
- **THEN** the item is labeled `unknown` and routed to the default kind without
  aborting

#### Scenario: a timeout falls back and never stalls the run

- **WHEN** a `pi` invocation is still running after the configured
  `timeout_seconds` elapses
- **THEN** the child process is killed, the item is labeled `unknown`, routed to
  the default kind, and logged, and evaluation of any remaining items and the
  enclosing run continue

#### Scenario: failure never propagates as a caller error

- **WHEN** an evaluation fails
- **THEN** the evaluator returns a kind (the default), not an error

### Requirement: Evaluation cache

The system SHALL cache successful longevity classifications, keyed on the
hex-encoded SHA-256 of the item's concatenated title and body, in a persistent
store under the XDG cache directory (`$XDG_CACHE_HOME/curation/eval-cache.json`,
resolving to `~/.cache/curation/...` when unset). A cache hit SHALL return the
kind without invoking `pi`. A cache entry SHALL be written only for a successful
(`short_term`/`long_term`) classification; an `unknown`/failed classification
SHALL NOT be cached, so a transient failure is retried on the next run. The
cache SHALL be loaded at evaluator construction.

#### Scenario: a cached item is not re-evaluated

- **WHEN** an item whose title+body was previously classified `knowledge` is
  classified again
- **THEN** the cache is hit, `pi` is not invoked, and the kind is `knowledge`

#### Scenario: a failed classification is not cached and is retried

- **WHEN** an item was classified `unknown` due to a pi failure and is
  classified again after pi recovers
- **THEN** the second classification invokes `pi` and records the successful
  result

#### Scenario: the cache survives a restart

- **WHEN** an item is classified and the process restarts
- **THEN** the persisted cache entry is loaded and the item is a cache hit

### Requirement: Evaluation configuration

The system SHALL read longevity-evaluation configuration from an optional
nested `pi` object in the same JSON config file loaded by the server
capability, using `std.json`. The object SHALL recognize `path` (the `pi`
binary path, default `pi`), `model` (optional, passed to `pi` as `--model`),
`prompt` (the classification prompt with `{title}` and `{body}` placeholders),
`default_kind` (the failure-fallback kind, default `news`), and
`timeout_seconds` (the per-invocation timeout in seconds; enforced by bounding
each `pi` subprocess and killing it on expiry, default `30`; a JSON `null`
disables the bound). When the `pi` object is absent, the fields SHALL take
their documented defaults. Fields not in the schema SHALL be ignored.

#### Scenario: absent pi block uses defaults

- **WHEN** the config file omits the `pi` object
- **THEN** the evaluator uses the default path `pi`, the default prompt,
  `default_kind` `news`, and a `timeout_seconds` of `30`

#### Scenario: custom prompt and model are applied

- **WHEN** the config `pi` object sets `model` to `flash` and a custom `prompt`
- **THEN** the evaluator invokes `pi` with `--model flash` and renders the
  custom prompt

#### Scenario: unknown fields are ignored

- **WHEN** the `pi` object contains an unrelated `future_field`
- **THEN** parsing succeeds and `future_field` does not cause an error

### Requirement: Evaluation observability

The longevity evaluator SHALL accept an optional metrics recorder — a nullable
handle to the `server` capability's metrics registry, mirroring the log writer
the evaluator already takes — and, for each classification that reaches an
actual `pi` invocation (a cache miss; a cache hit is not an evaluation), SHALL
record into it, exactly once per invocation: one evaluation, the invocation's
latency, and one failed evaluation when the invocation errors or its stdout
yields the label `unknown` (an unparseable result). A cache hit SHALL record
nothing. A `null` recorder SHALL record nothing and SHALL leave the evaluator
otherwise unchanged. A recording failure SHALL be non-fatal: it SHALL be logged
and SHALL NOT abort the evaluation, change the returned `Kind`, or prevent a
successful classification from being written to the cache. The recorded metrics
are exposed by the `server` capability's `/metrics` endpoint; the evaluator
SHALL perform no HTTP serving, no daily scheduling, and no item storage in this
requirement. The label-to-kind mapping, strict label parsing, failure-tolerance
fallback, evaluation cache, and evaluation-configuration requirements are
unchanged by this requirement.

#### Scenario: a cache-miss evaluation records the count and a latency sample

- **WHEN** the evaluator classifies an item that misses the cache and `pi`
  returns a parseable label, with a non-null recorder
- **THEN** the recorder has recorded one evaluation, one latency sample, and
  zero failures, and the returned `Kind` is unchanged from the same call with a
  null recorder

#### Scenario: a failed invocation records a failure

- **WHEN** the evaluator classifies an item that misses the cache and the `pi`
  invocation errors (the binary cannot start, exits non-zero, or times out),
  with a non-null recorder
- **THEN** the recorder has recorded one evaluation and one failure, the
  evaluator returns the configured-default `Kind`, and the run is not aborted

#### Scenario: an unparseable result records a failure

- **WHEN** the evaluator classifies an item that misses the cache and `pi`
  returns output that parses to `unknown`, with a non-null recorder
- **THEN** the recorder has recorded one evaluation and one failure, and the
  evaluator returns the configured-default `Kind`

#### Scenario: a cache hit records nothing

- **WHEN** the evaluator classifies an item that is present in its cache (no
  `pi` invocation), with a non-null recorder
- **THEN** the recorder has recorded no evaluation, no latency sample, and no
  failure, because no `pi` invocation occurred

#### Scenario: a null recorder is a no-op and the kind is unchanged

- **WHEN** the evaluator classifies an item with a null recorder
- **THEN** it records nothing and returns the same `Kind` and writes the cache
  exactly as it would with a recorder, so the evaluator stays usable and
  deterministic with no registry

#### Scenario: a recording failure is non-fatal

- **WHEN** the recorder cannot accept a recording (an allocator error) during a
  classification
- **THEN** the evaluator logs the recording failure, still returns the correct
  `Kind` for the item, and does not abort the enclosing run

