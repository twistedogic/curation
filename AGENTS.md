# AGENTS.md

Guidelines for AI agents and contributors working on **curation**.

## Project

`curation` is an HTTP server (a single static binary) that curates RSS/Atom
feeds and web content into incremental EPUB files for offline e-reader
reading. A daily curation job fetches sources, dedupes, filters, tags, caps,
then labels each surviving item **short-term** or **long-term** via the local
`pi` agent CLI. Items split into two per-kind streams — **news**
(short-term) and **knowledge** (long-term) — each with its own watermark and
incremental EPUB download. The design source of truth is `.see/intent.md`.

## Tech Stack

- **Zig 0.16.0**, stdlib-only, single static binary (`build.zig.zon` declares
  no dependencies). Use the standard library first — `std.http.Server` /
  `std.http.Client`, `std.zip` (EPUB), `std.json` (config + storage),
  `std.crypto.hash.sha2` (eval cache), `@embedFile` (UI). Do not add an
  in-binary dependency without strong justification.
- **External runtime tools are out-of-process and configured, never vendored:**
  - **Lightpanda** (`lightpanda fetch --dump markdown <url>`) renders web
    content; missing binary or failed render → source skipped and logged.
  - **`pi`** (the local agent CLI) makes the only model call: longevity
    classification. `curation` holds no provider/model/API-key config — `pi`
    does.
- **Config:** JSON via `std.json`, default
  `$XDG_CONFIG_HOME/curation/config.json` (`--config` / `CURATION_CONFIG` override).
- **Storage:** append-only JSONL item log + in-memory per-kind index.

## Build & Test

Everything runnable goes through [`Taskfile.yml`](Taskfile.yml)
([Task](https://taskfile.dev/docs/getting-started)), identical locally and in
CI:

```sh
task build             # zig build -Doptimize=Debug (OPTIMIZE=ReleaseFast for release)
task test              # zig build test
task run -- <args>     # build + run, e.g. task run -- serve
task clean             # rm -rf zig-out .zig-cache
```

Never add a dependency or change that breaks `task build` / `task test`.

## Architecture (src/)

- `main.zig` — CLI entry; dispatches to `server.run`; pulls in all test modules.
- `server.zig` — HTTP server lifecycle, routing, scheduler, signal handling.
- `config.zig` — JSON config struct + XDG path resolution.
- `fetch.zig` / `feed.zig` — feed fetch (`std.http.Client`) + RSS/Atom subset parser.
- `render.zig` — web content acquisition via the Lightpanda subprocess.
- `curation.zig` / `curation_job.zig` — the pipeline (normalize → dedupe → filter → tag → cap) and the run driver.
- `longevity.zig` — `pi` wrapper + SHA-256 evaluation cache.
- `store.zig` — JSONL item store + per-kind index + age-based retention prune.
- `download.zig` — token codec + per-kind EPUB builder (`std.zip`).
- `ui.zig` / `ui.html` — embedded download UI (`@embedFile`).
- `opml.zig` — OPML import.
- `auth.zig` / `log.zig` / `metrics.zig` — bearer gate, structured logging, Prometheus exposition.

## Code Conventions

- **Stdlib and native first; deletion over addition; boring over clever.** The
  shortest correct diff wins, once the problem is fully understood.
- **Mark deliberate simplifications** with a
  `// ponytail: <ceiling>; upgrade when <trigger>` comment so shortcuts are
  tracked rather than forgotten.
- **Structured logging** via `log.zig` (`level=... event=... key=value ...`),
  not ad-hoc printing.
- **Prometheus metrics** via `metrics.zig` for any new server operation
  (counters / gauges / histograms exposed at `GET /metrics`).
- **Tests:** every non-trivial logic path has a runnable self-check under
  `zig build test` (co-located `test` blocks). Keep `task test` green.

## Documentation

- Spell out acronyms on first use (e.g., "Application Programming Interface
  (API)"), then the acronym alone.

## Spec-Driven Changes

- Use [OpenSpec](openspec/) (`openspec/specs/` capabilities, `openspec/changes/`
  proposals) for non-trivial changes. Validate with
  `npx -y @fission-ai/openspec@latest validate --all`. Archive a change after merge.

## CI / Automation

- [Task](https://taskfile.dev/docs/getting-started) (`Taskfile.yml`) is the CI
  runner and shared automation entry point; keep commands reproducible locally
  and in CI. GitHub Actions (`.github/workflows/ci.yml`) runs OpenSpec
  validation, build+test on every push/PR, and cross-compiled binary releases
  on version tags.

## Commit Messages

- Never add agent names as author or co-author. Commits reflect the human
  contributor only.

## Bug Fixes

- Reproduce first, add a failing test case before the fix, and never merge a
  bug fix without a regression test.

## Technical Decisions

- Weight correctness, readability, simplicity, and long-term maintainability
  over development cost and time. Choose what we'd live with for years.

## Observability

- Prefer structured logging (key/value, consistent levels, machine-parseable)
  over unstructured strings. For the server, expose Prometheus metrics
  (counters, gauges, histograms) on a standard scrape endpoint.

## Maintenance

- Keep this file and `.see/intent.md` current with key decisions and
  workflows. Update them in the same change that a decision or workflow
  changes.
