## MODIFIED Requirements

### Requirement: JSON configuration loading

The system SHALL load its configuration from a JSON file parsed with
`std.json`. The default path SHALL be `$XDG_CONFIG_HOME/curation/config.json`
(resolving to `~/.config/curation/config.json` when `XDG_CONFIG_HOME` is
unset), overridable via a `--config <path>` flag and a `CURATION_CONFIG`
environment variable (flag takes precedence over env, env over default). The v1
schema SHALL recognize at minimum `host` (string), `port` (u16), `auth_token`
(string), `sources` (a list of feed source objects each carrying `name`
(string) and `url` (string)), `web_sources` (a list of web-content source
objects each carrying `name` (string) and `url` (string)), `lightpanda` (an
object carrying `path` (string, default `lightpanda`) and `dump_format` (one of
`markdown` or `html`, default `markdown`)), and `schedule` (a string of the form
`HH:MM` denoting the daily local curation time, default `04:00`). When
`sources` or `web_sources` is absent it SHALL be treated as an empty list; when
`schedule` is absent it SHALL be treated as `04:00`; when the `lightpanda`
object is absent its fields SHALL take their documented defaults. Fields not in
the schema SHALL be ignored so later changes extend the file without breaking
this loader.

#### Scenario: default config path resolves via XDG

- **WHEN** `XDG_CONFIG_HOME=/tmp/xdg` and no flag/env is set
- **THEN** the loader reads `/tmp/xdg/curation/config.json`

#### Scenario: flag overrides environment

- **WHEN** `--config /etc/c.json` is given and `CURATION_CONFIG=/other` is set
- **THEN** the loader reads `/etc/c.json`

#### Scenario: unknown fields are ignored

- **WHEN** the config file contains `{"host":"0.0.0.0","port":1,"future_field":42}`
- **THEN** parsing succeeds and `future_field` does not cause an error

#### Scenario: missing config file fails loudly

- **WHEN** the resolved config path does not exist
- **THEN** startup logs an ERROR with the path and exits non-zero before
  binding any port

#### Scenario: absent sources defaults to an empty list

- **WHEN** the config file omits `sources`
- **THEN** the loaded configuration has zero feed sources

#### Scenario: sources are parsed with name and url

- **WHEN** the config file sets `sources` to
  `[{"name":"hackernews","url":"https://news.ycombinator.com/rss"}]`
- **THEN** the loaded configuration has one feed source whose `name` is
  `hackernews` and whose `url` is that feed URL

#### Scenario: absent web_sources defaults to an empty list

- **WHEN** the config file omits `web_sources`
- **THEN** the loaded configuration has zero web-content sources

#### Scenario: web sources are parsed with name and url

- **WHEN** the config file sets `web_sources` to
  `[{"name":"cnn","url":"https://www.cnn.com"}]`
- **THEN** the loaded configuration has one web-content source whose `name` is
  `cnn` and whose `url` is `https://www.cnn.com`

#### Scenario: an absent lightpanda block uses defaults

- **WHEN** the config file omits the `lightpanda` object
- **THEN** the loaded configuration's `lightpanda.path` is `lightpanda` and its
  `lightpanda.dump_format` is `markdown`

#### Scenario: a custom lightpanda block is parsed

- **WHEN** the config file sets `lightpanda` to
  `{"path":"/opt/lightpanda","dump_format":"html"}`
- **THEN** the loaded configuration's `lightpanda.path` is `/opt/lightpanda` and
  its `lightpanda.dump_format` is `html`

#### Scenario: absent schedule defaults to 04:00

- **WHEN** the config file omits `schedule`
- **THEN** the loaded configuration's daily curation time is `04:00`
