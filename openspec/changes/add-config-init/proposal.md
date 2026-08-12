## Why

An operator's first run today requires hand-writing a JSON config and
inventing a bearer token, and there is no bootstrap step: `serve` already
errors with `config.missing` when the config file is absent. Two frictions make
this worth fixing. First, `auth_token` is the one field that should never be
hand-chosen, and an omitted/empty token leaves the bearer gate
(`src/auth.zig` `checkBearer`) in a degenerate state — a header of exactly
`Authorization: Bearer ` (empty token) is *accepted* against an empty
configured token, because the length check passes at zero and the constant-time
loop iterates zero times. Second, the documented happy path ("run the server")
presupposes a config file that nothing creates. A `curation init` command is
the missing first step: it writes a default config with a generated token to
the resolved XDG path, ahead of `curation import <opml>` (sources) and
`curation serve`.

## What Changes

- Add a `curation init` subcommand, dispatched in `src/server.zig` alongside
  `serve` and `import`. It writes a default configuration to the resolved
  config path with a generated `auth_token`, then prints the path, the token,
  and the next steps (`import` sources, then `serve`).
- **Non-interactive.** It writes `Config{}` field defaults — host, port, rules,
  `retention_days`, `pi`, `lightpanda`, `schedule` are already sane — with only
  `auth_token` set to a generated value. No wizard, no TUI (consistent with the
  intent's "feed and rule config stays file-driven" non-goal).
- **Generate the token** as the base64url encoding of 32 random bytes from
  `std.Io.random` (the same entropy source `Config.write` already uses for its
  temp-file id), so a fresh config never ships in the empty-token state.
- **Refuse to clobber.** If a config already exists at the resolved path,
  `init` errors and writes nothing unless `--force` is passed — protecting an
  operator's existing token, sources, and rules.
- **Reuse existing machinery, unchanged:** config-path resolution
  (`Config.resolvePath`: XDG / `--config` / `CURATION_CONFIG`) and the atomic
  config writer (`Config.write`: temp file + rename, specified by the
  `opml-import` capability). `init` creates the config *directory* (its own
  precondition, the one thing `Config.write` assumes exists) before writing;
  `Config.write` itself is not modified.
- No new dependency (stdlib-only); no store, JSONL record, token, EPUB, route,
  or `/metrics` change.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `server`: gains a "Configuration bootstrap command" requirement — a
  `curation init` subcommand that writes a default config (with a generated
  bearer token) to the resolved config path, creating the config directory if
  needed and refusing to overwrite an existing config unless `--force` is
  given. This is the create/write counterpart to `server`'s existing "JSON
  configuration loading" requirement; subcommand dispatch already lives in
  `server`, where `init` joins `serve` and `import`. The `opml-import`
  capability's "Atomic configuration rewrite" requirement is reused, not
  changed.

## Impact

- **Code:** `src/server.zig` — a new `init` branch in `run`'s dispatcher and an
  `initCommand` handler (resolve path → refuse-if-exists unless `--force` →
  `createDirPath` the config directory → generate the token → `Config.write`
  → print path/token/next steps), plus a usage-string line. A small
  token-generation helper (`std.Io.random` → `std.base64.url_safe_no_pad`) is
  inlined here unless a second caller appears. No other `.zig` file changes.
- **Config:** creates `$XDG_CONFIG_HOME/curation/` (or the parent of a
  `--config` path) if absent, then writes a default `config.json` whose only
  non-default field is the generated `auth_token`. No schema change — every
  field already defaults inside `Config`. `Config.write` is reused unchanged.
- **APIs / dependencies:** none. Stdlib only (`std.Io.random`,
  `std.base64.url_safe_no_pad`, `std.Io.Dir.createDirPath`). Single binary.
- **Out of scope (noted adjacent gap):** on a truly fresh system, `serve`'s
  first curation run can still fail because `Store.append`
  (`$XDG_DATA_HOME/curation/`) and `EvalCache.persist`
  (`$XDG_CACHE_HOME/curation/`) do not create their parent directories. `init`
  deliberately does not paper over this; the root fix (`createDirPath` before
  first write in `Store`/`EvalCache`) is a separate change.
- **Automation:** no `Taskfile.yml` or CI change; `task run -- init` exercises
  the command end-to-end.
