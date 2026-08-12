## ADDED Requirements

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
