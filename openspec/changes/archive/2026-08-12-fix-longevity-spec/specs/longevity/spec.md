## ADDED Requirements

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
the fallback kind rather than an error to its caller.

#### Scenario: a missing pi binary falls back

- **WHEN** the configured `pi` binary cannot be started
- **THEN** the item is labeled `unknown`, routed to the default kind, and
  logged, and evaluation continues

#### Scenario: a non-zero exit falls back

- **WHEN** the pi invocation exits non-zero
- **THEN** the item is labeled `unknown` and routed to the default kind without
  aborting

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
`timeout_seconds` (optional). When the `pi` object is absent, the fields SHALL
take their documented defaults. Fields not in the schema SHALL be ignored.

#### Scenario: absent pi block uses defaults

- **WHEN** the config file omits the `pi` object
- **THEN** the evaluator uses the default path `pi`, the default prompt, and
  `default_kind` `news`

#### Scenario: custom prompt and model are applied

- **WHEN** the config `pi` object sets `model` to `flash` and a custom `prompt`
- **THEN** the evaluator invokes `pi` with `--model flash` and renders the
  custom prompt

#### Scenario: unknown fields are ignored

- **WHEN** the `pi` object contains an unrelated `future_field`
- **THEN** parsing succeeds and `future_field` does not cause an error
