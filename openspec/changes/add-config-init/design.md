## Context

`curation serve` errors with `config.missing` when the config file is absent,
and the only way to produce one today is to hand-write JSON and invent a bearer
token. The token is the friction: `auth.zig`'s `checkBearer` accepts an
`Authorization: Bearer ` header (empty token) against an empty configured
token — the length check passes at zero and the constant-time loop runs zero
iterations — so an operator who omits `auth_token` lands in a degenerate auth
state. `init` is the missing bootstrap step: write a default config with a
generated token to the resolved path, ahead of `import` (sources) and `serve`.

Everything `init` needs already exists and is reused unchanged:
- `Config.resolvePath` — XDG / `--config` / `CURATION_CONFIG` path resolution.
- `Config.write` — atomic temp-file + rename (specified by the `opml-import`
  capability's "Atomic configuration rewrite" requirement).
- `Config{}` field defaults — host, port, rules, `retention_days`, `pi`,
  `lightpanda`, `schedule` are already correct.
- `std.Io.random` — the entropy source `Config.write` already uses for its
  temp-file id.

The design is therefore mostly glue plus one generated secret. The decisions
below are the ones with a real choice.

## Goals / Non-Goals

**Goals:**
- One command (`curation init`) that takes a fresh system to a runnable config.
- A config that never ships in the empty-`auth_token` degenerate state.
- Compose with the existing flow: `init` → `import <opml>` → `serve`.
- Reuse `Config.write` and `resolvePath` unchanged; no new module or dependency.

**Non-Goals:**
- No interactive wizard / TUI (config stays file-driven; sources come from
  `import`).
- No seeding of example sources — JSON has no comments, so an "example" would
  be a real active source; `init` stays orthogonal to `import`.
- No fix for the adjacent first-run gap: `Store.append`
  (`$XDG_DATA_HOME/curation/`) and `EvalCache.persist`
  (`$XDG_CACHE_HOME/curation/`) do not create their parent dirs, so `serve`'s
  first curation run can still fail on a fresh system. `init` does not paper
  over this — the root fix (`createDirPath` before first write in
  `Store`/`EvalCache`) is a separate change.

## Decisions

**D1. Non-interactive: write `Config{}` defaults + a generated token.**
The intent's non-goal is "feed and rule config stays file-driven" / "no TUI".
`Config{}` defaults are already the right values for every field except
`auth_token`. A one-shot wizard (prompt for host/port/sources) would be a
posture shift and would duplicate `import`'s job. *Alternative rejected:*
interactive prompts.

**D2. Token = base64url of 32 random bytes via `std.Io.random`.**
256 bits of entropy; base64url is URL-safe and ~43 chars; `std.Io.random` is
already in use (`Config.write`'s temp id), so no new entropy source or
dependency. *Alternatives rejected:* hex (64 chars, longer for no gain);
reading `/dev/urandom` directly (stdlib already wraps it); fewer bytes.

**D3. Refuse if a config exists, unless `--force`.**
The one thing that hurts to lose is an operator's configured token + sources +
rules; silently clobbering is the worst default. `--force` covers intentional
re-bootstrap. "Exists" = the resolved path is present (stat/access).
*Alternatives rejected:* always overwrite (dangerous); merge existing into
defaults (complex, YAGNI).

**D4. `init` creates the config directory; `Config.write` is unchanged.**
`Config.write` assumes its target directory exists (true for `import`, which
writes into an existing config's dir). `init` is the one caller writing where no
file — and likely no dir — exists, so it owns that precondition: `createDirPath`
the config dir before writing. *Alternative rejected:* make `Config.write`
itself `createDirPath` its parent (a root fix benefiting any future caller).
Rejected as YAGNI — only `init` needs it today — and because altering
`Config.write`'s contract would pull the `opml-import` capability into scope for
no behavior gain. The dir is created locally in `init`, keeping the change to
`server` only.

**D5. One handler in `server.zig`; token helper inlined.**
`init` is a dispatcher branch + an `initCommand` handler + a small
random→base64url helper, all in `src/server.zig` (where `serve`/`import`
dispatch already lives). No new file. The helper lifts to a shared util only if
a second caller appears.

## Risks / Trade-offs

- **[Token printed to the terminal]** → It is a bootstrap secret shown once,
  like `openssl rand`. The config file is the durable source of truth, so the
  operator need not rely on the terminal scrollback. Acceptable; the UI flow
  needs the operator to possess the token anyway.
- **[Refuse default surprises someone expecting overwrite]** → `--force` exists
  and the error message names it. The conservative default is correct for an
  irreversible clobber.
- **[TOCTOU: config created between the exists-check and the write]** → The
  exists-check is a best-effort guard, not a lock; `Config.write` is itself
  atomic (temp + rename). Single-operator tool; acceptable.
  `// ponytail: exists-check then atomic write, no lock; revisit if concurrent
  operators ever share a config path.`
- **[Doesn't fix the data/cache dir first-run gap]** → Documented as a non-goal;
  the root fix belongs in `Store`/`EvalCache`, separately.

## Open Questions

None blocking — defaults chosen for each decision above. The one worth flagging
for review: whether `--force` should also be the *only* way to write when the
file exists (current choice), vs. a `--merge` that fills only missing fields
(deferred — YAGNI until an operator asks).
