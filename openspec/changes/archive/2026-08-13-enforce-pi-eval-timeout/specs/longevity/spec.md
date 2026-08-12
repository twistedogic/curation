## MODIFIED Requirements

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
