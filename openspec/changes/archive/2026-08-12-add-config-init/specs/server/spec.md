## ADDED Requirements

### Requirement: Configuration bootstrap command

The system SHALL provide a `curation init` command that writes a default
configuration to the resolved configuration path — the same XDG / `--config` /
`CURATION_CONFIG` resolution used by `serve` — with a generated `auth_token`,
creating the configuration directory if it does not exist. The generated token
SHALL be opaque and randomly chosen. Every configuration field other than
`auth_token` SHALL take its default value. If a configuration file already
exists at the resolved path, the command SHALL write nothing, report the
existing path, and exit non-zero, unless `--force` is given; with `--force` it
SHALL overwrite the existing file with a fresh default configuration and a
newly generated token. On success the command SHALL print the written path, the
generated token, and a short next-steps message, and SHALL exit zero. The
command SHALL be non-interactive, SHALL perform no source acquisition (no HTTP
fetch, no Lightpanda or `pi` subprocess, no curation run), and SHALL not start
the server. The written configuration SHALL be loadable by the configuration
loader.

#### Scenario: init writes a default config with a generated token

- **WHEN** the operator runs `curation init` with no existing configuration at
  the resolved path
- **THEN** a configuration file is written at the resolved path whose
  `auth_token` is non-empty and whose every other field equals its default, and
  the command exits 0

#### Scenario: init creates a missing configuration directory

- **WHEN** the resolved configuration path's parent directory does not exist
- **THEN** `curation init` creates that directory and writes the configuration
  there

#### Scenario: init refuses to overwrite an existing configuration

- **WHEN** the operator runs `curation init` and a configuration already exists
  at the resolved path (and `--force` is not given)
- **THEN** the command writes nothing, reports the existing path, and exits
  non-zero

#### Scenario: --force overwrites an existing configuration

- **WHEN** the operator runs `curation init --force` and a configuration already
  exists at the resolved path
- **THEN** the command overwrites the file with a fresh default configuration
  and a newly generated token, and exits 0

#### Scenario: init honors the same path resolution as serve

- **WHEN** `--config <path>` is given, or `CURATION_CONFIG` is set, or neither
  and the XDG default applies
- **THEN** `curation init` writes to the same path `curation serve` would read
  — flag taking precedence over environment, environment over the XDG default

#### Scenario: init is non-interactive and performs no acquisition

- **WHEN** the operator runs `curation init`
- **THEN** it performs no HTTP fetch, spawns no Lightpanda or `pi` subprocess,
  runs no curation job, and starts no server

#### Scenario: the written configuration round-trips through the loader

- **WHEN** `curation init` has written a configuration
- **THEN** the configuration loader loads it successfully with the generated
  `auth_token` preserved and defaults for every other field

#### Scenario: init prints the path, token, and next steps

- **WHEN** `curation init` writes a configuration successfully
- **THEN** it prints the written path, the generated token, and a next-steps
  message naming `import` (to add sources) and `serve` (to run)
