## ADDED Requirements

### Requirement: Curated item model

The curation pipeline SHALL operate over input item records, each carrying at
minimum the fields `title` (string), `url` (string, possibly empty), `body`
(string, possibly empty), `date` (string), and `source` (string). Its output
SHALL be curated item records carrying every input field unchanged plus the
set of tag names the pipeline assigned to that item. The model SHALL hold no
I/O, scheduling, or network state — items are plain values.

#### Scenario: curated output preserves input fields

- **WHEN** the pipeline processes an item with title `T`, url `U`, body `B`,
  date `D`, source `S`
- **THEN** the output curated item carries those same five field values, in
  addition to its assigned tags

#### Scenario: empty url is a valid item

- **WHEN** an input item has an empty `url`
- **THEN** it is still a valid pipeline input (deduplication falls back to the
  title, per the normalization requirement)

### Requirement: Deterministic pipeline

The curation pipeline SHALL be a pure function of its input items and the
configured rules: for identical inputs it SHALL produce byte-identical output,
independent of wall-clock time, process, or host. It SHALL apply, in order:
normalize, dedupe, filter (include/exclude), tag, and cap. The pipeline SHALL
perform no network, filesystem, or subprocess I/O; this change's pipeline ends
at cap and does not classify longevity or persist items.

#### Scenario: same inputs yield same outputs

- **WHEN** the pipeline runs twice on the same items and the same rules
- **THEN** both runs return curated item records that are equal field-for-field
  and in the same order

#### Scenario: pipeline is pure of side effects

- **WHEN** the pipeline runs
- **THEN** it performs no reads from or writes to the network, the filesystem,
  or any child process

#### Scenario: stages run in defined order

- **WHEN** an item would be removed by dedupe, by filter, or by cap
- **THEN** only the earliest applicable stage removes it, and an item removed
  by an earlier stage is never tagged

### Requirement: Normalization and deduplication

The pipeline SHALL normalize a non-empty URL by lowercasing the scheme and
host, dropping any fragment (`#…`), and dropping a single trailing slash from
the path; the query string SHALL be preserved. It SHALL compute a dedupe key
of the normalized URL, or — when the URL is empty — of a stable hash of the
trimmed, lowercased title. Across all input items, the pipeline SHALL keep the
first occurrence of each dedupe key and drop later duplicates, preserving the
relative order of survivors.

#### Scenario: same URL differing only in case and fragment dedupes

- **WHEN** two items have URLs `HTTPS://Example.COM/a#frag` and
  `https://example.com/a`
- **THEN** they share a dedupe key and only the first survives

#### Scenario: trailing slash is ignored for dedupe

- **WHEN** two items have URLs `https://example.com/a/` and
  `https://example.com/a`
- **THEN** they share a dedupe key and only the first survives

#### Scenario: distinct query strings are not deduped

- **WHEN** two items have URLs `https://example.com/a?x=1` and
  `https://example.com/a?x=2`
- **THEN** they have distinct dedupe keys and both survive

#### Scenario: empty URL falls back to title hash

- **WHEN** two items have empty URLs and the same title `Hello` (ignoring case
  and surrounding whitespace)
- **THEN** they share a dedupe key and only the first survives

### Requirement: Filter rules (include/exclude)

The pipeline SHALL apply filter rules that each declare a match target (title
and/or URL) and a case-insensitive substring. An exclude rule SHALL drop any
item whose declared target(s) contain the substring. When one or more include
rules exist, an item SHALL pass only if it matches at least one include rule
(deny-by-default); when no include rules exist, every item passes the include
gate (allow-by-default). Filter SHALL run before tagging.

#### Scenario: exclude substring drops matching items

- **WHEN** rules contain an exclude rule on title `sponsored` and an item's
  title is `Acme — Sponsored Post`
- **THEN** that item is dropped from the output

#### Scenario: include rules are deny-by-default

- **WHEN** rules contain one include rule on title `rust` and an item's title
  is `News About Cars`
- **THEN** that item is dropped (it matched no include rule)

#### Scenario: no include rules allows everything

- **WHEN** there are no include rules (only exclude rules, or none)
- **THEN** every item that is not excluded passes the filter

#### Scenario: matching is case-insensitive

- **WHEN** an exclude rule on title `SPAM` is given and an item's title is
  `this is spam`
- **THEN** that item is dropped

### Requirement: Tag rules

The pipeline SHALL apply tag rules that each declare a tag name, a match
target (title and/or URL), and a case-insensitive substring; an item matching
a tag rule SHALL gain that rule's tag name. An item SHALL carry each tag name
at most once, regardless of how many rules matched it. Tagging SHALL run after
filtering and before the cap.

#### Scenario: a match assigns the tag

- **WHEN** a tag rule `ai` matches on title substring `LLM` and an item's
  title is `New LLM benchmark`
- **THEN** the output curated item's tag set contains `ai`

#### Scenario: repeated matches do not duplicate a tag

- **WHEN** two tag rules both assign tag `ai` and an item matches both
- **THEN** the output curated item's tag set contains `ai` exactly once

#### Scenario: filtered-out items are never tagged

- **WHEN** an item is dropped by a filter rule and would have matched a tag rule
- **THEN** it is absent from the output and no tag is computed for it

### Requirement: Per-run cap

The pipeline SHALL accept a per-run maximum item count. When set to a positive
value, the output SHALL contain at most that many curated items, taken in
surviving (post-dedupe/filter/tag) order. When unset or zero, the output SHALL
be unbounded. The cap SHALL be the final stage.

#### Scenario: cap truncates to the limit preserving order

- **WHEN** the cap is `3` and five items survive the earlier stages in order
  A, B, C, D, E
- **THEN** the output contains A, B, C only

#### Scenario: unset cap is unbounded

- **WHEN** no cap is configured and five items survive
- **THEN** the output contains all five

### Requirement: Rule configuration

Filter rules, tag rules, and the cap SHALL be configured as optional fields in
the same JSON config file loaded by the server capability, using `std.json`.
The schema SHALL recognize `filter_rules` (a list of include/exclude rules),
`tag_rules` (a list of tag rules), and `cap` (a non-negative integer). When
`filter_rules` is absent it SHALL be treated as empty; when `cap` is absent or
zero it SHALL be treated as unbounded. Fields not in the schema SHALL be
ignored so later changes extend the file without breaking this loader.

#### Scenario: absent rules default to pass-through

- **WHEN** the config file omits `filter_rules`, `tag_rules`, and `cap`
- **THEN** the pipeline applies no filtering, no tagging, and no cap

#### Scenario: unknown fields are ignored

- **WHEN** the config file contains a `filter_rules` list and an unrelated
  `future_field`
- **THEN** parsing succeeds, the filter rules are loaded, and `future_field`
  does not cause an error

#### Scenario: cap of zero means unbounded

- **WHEN** the config file sets `cap` to `0`
- **THEN** the pipeline output is unbounded
