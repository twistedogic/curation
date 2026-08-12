## 1. Token + path primitives

- [ ] 1.1 Add a small helper in `src/server.zig` that fills a buffer from
  `std.Io.random` and base64url-encodes it (`std.base64.url_safe_no_pad`) into a
  `gpa`-owned slice — the generated `auth_token` (design D2). Inline in
  `server.zig`; lift to a shared util only if a second caller appears.
- [ ] 1.2 Reuse `Config.resolvePath` (XDG / `--config` / `CURATION_CONFIG`) for
  the `init` target path and `Config.write` (atomic temp+rename) for the write —
  both unchanged (design D4/D5; spec: Configuration bootstrap command). No new
  module, no new dependency.

## 2. `curation init` command

- [ ] 2.1 Add an `init` branch to `run`'s dispatcher in `src/server.zig`
  (parallel to `serve`/`import`) plus a usage-string line. Parse `--config` and
  `--force` flags (spec: Configuration bootstrap command).
- [ ] 2.2 `initCommand`: resolve the path; if a config exists there and
  `--force` is not set, report the existing path and return non-zero **without
  writing** (spec scenarios: refuses to overwrite). With `--force`, proceed to
  overwrite.
- [ ] 2.3 `createDirPath` the config path's parent if needed (spec scenario:
  creates a missing configuration directory), then
  `Config.write(.{ .auth_token = <generated> }, path)` — every other field
  defaults (design D1, D4).
- [ ] 2.4 On success, print the written path, the generated token, and a
  next-steps message naming `import` (sources) and `serve` (run), and exit 0
  (spec scenario: prints the path, token, and next steps). The command performs
  no acquisition and starts no server (spec scenario: non-interactive).

## 3. Tests

- [ ] 3.1 Self-check: `init` against a temp config dir writes a config whose
  JSON round-trips through `Config.load` with the generated `auth_token`
  preserved and defaults for every other field (spec: round-trips through the
  loader; design D1).
- [ ] 3.2 Self-check: `init` creates a missing parent directory and writes
  there; re-running `init` on the existing path without `--force` writes
  nothing and returns non-zero; `init --force` overwrites with a fresh token
  (spec scenarios: creates a missing directory, refuses to overwrite, --force
  overwrites).
- [ ] 3.3 Self-check: `init` honors `--config` / env / XDG precedence via
  `resolvePath` (write target equals `serve`'s read target), and the generated
  token is non-empty and uses the base64url alphabet — assert shape, not a fixed
  value (spec scenario: honors the same path resolution as serve).

## 4. Integration

- [ ] 4.1 No new module to register (handler + helper live in `server.zig`,
  already in `main.zig`'s comptime test block); no public signature, store,
  JSONL, token, route, EPUB, or `/metrics` change.
- [ ] 4.2 `zig build test` green; `openspec validate add-config-init` passes;
  `openspec validate --all` stays green; `task run -- init` exercises the
  command end-to-end.
