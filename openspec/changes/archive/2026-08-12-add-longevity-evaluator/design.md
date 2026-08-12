## Context

`curation` has the server bedrock (config, lifecycle, `/healthz`, auth gate,
logging, `/metrics`), the pure curation pipeline ending at cap, and feed
fetching + parsing. `.see/intent.md` fixes the full pipeline order as
normalize → dedupe → filter → tag → cap → **longevity evaluation via pi
(FR-15)** → route to news/knowledge stream → store (FR-5), and calls the
pipeline *minus evaluation* "pure and deterministic" (intent §2, §7; US-009).
The `curation` spec is explicit that its pipeline "ends at cap and does not
classify longevity."

This change adds the longevity stage and nothing more. It is the next slice in
data-flow order, and it is deliberately isolated: it is the only
non-deterministic step, so it is kept behind a seam, made idempotent via a
cache, and made non-fatal via a configured-default fallback. Storage (FR-6),
the daily schedule / `POST /curate` (US-002), EPUB/download (US-004), and the
web (Lightpanda) path (US-008) are all later changes that consume the kind
this evaluator produces.

## Goals / Non-Goals

**Goals:**
- A `Label` (`short_term` | `long_term` | `unknown`) and a `Kind`
  (`news` | `knowledge`), with the fixed mapping short_term→news,
  long_term→knowledge, and `unknown` → configured default kind (default
  `news`).
- An evaluator `classify(allocator, item) -> Kind` that renders the prompt,
  consults the SHA-256(title+body) cache, and otherwise invokes `pi`, parses
  one token, writes the cache, and applies the fallback.
- A persisted SHA-256-keyed cache in the XDG cache dir so re-runs skip already
  classified content.
- Failure tolerance: pi missing / non-zero / timeout / unparseable → `unknown`
  → default kind, logged, non-fatal.
- A `pi` config block (path, optional model, prompt, default_kind, optional
  timeout) in the existing JSON config; curation holds no credentials.
- An injectable pi-invoker seam so the parse/cache/fallback core is
  unit-tested without `pi`.

**Non-Goals:**
- Wiring evaluation into the daily job or any endpoint — the evaluator is a
  library called by the orchestration change later.
- Persistence of items (FR-6 JSONL store), retention (FR-16), the two EPUBs,
  `/download`, tokens, and the embedded UI — all later.
- A `pi` SDK or in-process model integration — all model access stays the
  out-of-process `pi` CLI (intent Non-Goals: "No direct LLM provider
  integration").
- A neutral/`uncertain` third label beyond `unknown`-as-failure — deferred to
  the prompt-refinement ceiling (intent §9 D13).
- Long-running/`serve`-mode pi sessions — one ephemeral call per item this cut.

## Decisions

### D1. One ephemeral `pi` call per item, behind an injectable seam
Production invokes `pi` once per uncached item via `std.process.Child`, piping
the rendered prompt to `pi` and reading one short answer on stdout. The
evaluator takes an `Invoker` — a function pointer taking the eval config and
rendered prompt and returning either stdout bytes or an error — so the
classification logic (cache lookup → invoke → parse → cache write → fallback)
is exercised in tests with a stub invoker returning canned output, errors, or
garbage. The real subprocess invoker is a thin function used only in
production.
- *Alternative:* call `pi` directly inline. Rejected — untestable without `pi`
  installed, and it would couple the pure label/cache/fallback logic to a
  subprocess spawn.
- `// ponytail: one process spawn per uncached item; move to a persistent
  pi serve/session if per-item spawn overhead matters at high item counts.`

### D2. Strict single-token parsing
Parse `pi` stdout for the tokens `short_term` and `long_term`
(case-insensitive, matched at a token boundary). The first valid token wins;
anything else (empty, `short-term` with a hyphen, prose, JSON, an error
string) is treated as `unknown` → fallback. This is deliberately strict: a
loose parser that "guesses" misfiles content silently; a strict one routes
ambiguous output to the safe default and is logged.
- *Alternative:* fuzzy/proximity parsing. Rejected for v1 — strict + fallback
  is the debuggable choice; loosen only if real `pi` output needs it.

### D3. `unknown` → default kind `news` (misfile-as-disposable)
On any failure (D1/D2), the item is labeled `unknown` and routed to the
configured default kind, default `news`. Intent §9 D13 fixes this: misfiling
as disposable news is safer than polluting the durable knowledge library. The
label is recorded and logged at WARN. `unknown` is a failure result, not a
successful classification — see D4, it is not cached, so a later re-run with a
recovered `pi` re-evaluates.
- *Alternative:* `unknown` → `knowledge`. Rejected per intent D13.
- *Alternative:* drop the item on failure. Rejected — never block storage on
  the one non-deterministic step (intent §2.4: the evaluator "never gates
  whether an item is stored").

### D4. Cache key = SHA-256(title+body), hex; `unknown` is never cached
The cache maps `{sha256hex(title||body): "news"|"knowledge"}` and is consulted
before invoking `pi`. Only *successful* classifications are written; an
`unknown`/failure is **not** cached, so a transient `pi` outage does not
permanently misfile content — the next run retries. The cache is persisted as
one JSON object in `$XDG_CACHE_HOME/curation/eval-cache.json` (`std.json`),
loaded at construction and rewritten after each new successful evaluation.
- *Alternative:* in-memory cache only. Rejected — intent US-009 wants re-runs
  *across restarts* to not re-spend.
- *Alternative:* cache `unknown` too. Rejected — would freeze transient
  failures into permanent misfiles.
- `// ponytail: whole-file JSON rewrite on each new eval; fine at daily digest
  volume (tens–low hundreds, mostly cached). Switch to an append-log/SQLite
  cache if the file grows or write cost shows up.`

### D5. Eval config as a nested `pi` object, decoded by the existing loader
Add `pi` (object) to `Config` with fields `path` (default `"pi"`), `model`
(optional, passed as `--model`), `prompt` (the classification prompt with
`{title}`/`{body}` placeholders, defaulting to the intent §9 prompt),
`default_kind` (default `"news"`), and `timeout_seconds` (optional). The
existing `std.json` loader ignores unknown fields and applies struct defaults,
so loading behavior is unchanged. A nested object groups this coherent
eval-config group (cf. `curation` design D6, which deferred nesting until rule
groups multiplied — here the group already exists).
- *Alternative:* flat fields (`pi_path`, `pi_model`, …). Rejected — noisier
  than one nested block for a coherent tool config.

### D6. Prompt rendering by simple `{title}`/`{body}` substitution
The evaluator renders the configured prompt by replacing the literal
placeholders `{title}` and `{body}` with the item's fields (no full template
engine). The default prompt is the intent §9 classifier prompt. The same text
may be mirrored at `.pi/prompts/longevity.md` for manual/debug use, but the
source of truth at runtime is the config value.
- `// ponytail: placeholder substitution, not a template engine; add helpers
  if prompts need conditionals or loops.`

## Risks / Trade-offs

- **[pi output drift breaks parsing]** → Mitigation: strict single-token parse
  (D2) + `unknown`→fallback; WARN-logged so drift is visible in logs and later
  metrics.
- **[Transient pi outage permanently misfiles items]** → Mitigation: never
  cache `unknown` (D4); the next run retries. The fallback is to the safe,
  disposable `news` stream (D3).
- **[Eval cost on large uncapped bursts]** → Mitigation: the curation cap
  (US-003, already landed) bounds items per run, so evaluator cost per run is
  bounded; the cache absorbs repeats.
- **[Cache file grows / rewrite cost]** → Mitigation: ponytail ceiling noted
  (D4); move to append-log/SQLite if retention/scan cost bites.
- **[Config shape churn for `pi` block]** → Mitigation: minimal, defaulted
  nested block (D5); the loader's unknown-field tolerance absorbs additions.

## Migration Plan

Greenfield and additive — no migration. Deploy by: add an optional `pi` block
to `config.json` (all fields defaulted; omitting it leaves evaluation at
defaults but buildable). No store, endpoint, or runtime behavior changes in
this cut (the server keeps serving the placeholder `/`); the evaluator is
exercised only by `zig build test` with a stubbed invoker, plus an opt-in
manual check against a real `pi`. Rollback is `git revert`.

## Open Questions

- None blocking. Whether `pi` takes the prompt via `-p` arg or stdin is a
  runtime detail hidden behind the invoker seam (D1); the production invoker is
  tuned to the actual `pi` CLI in implementation. A neutral third label
  (D2 / intent §9 D13) is a deliberate later ceiling.
