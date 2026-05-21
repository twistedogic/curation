# AGENTS.md

Guidelines for AI agents and contributors.

## Documentation

- Spell out acronyms on first use (e.g., "Application Programming Interface (API)"), then the acronym alone.

## CI / Automation

- Use [Task](https://taskfile.dev/docs/getting-started) (a `Taskfile.yml`) as the CI runner and shared automation entry point; keep commands reproducible locally and in CI.

## Commit Messages

- Never add agent names as author or co-author. Commits reflect the human contributor only.

## Bug Fixes

- Reproduce first, add a failing test case before the fix, and never merge a bug fix without a regression test.

## Technical Decisions

- Weight correctness, readability, simplicity, and long-term maintainability over development cost and time. Choose what we'd live with for years.

## Observability

- Prefer structured logging (key/value, consistent levels, machine-parseable) over unstructured strings.
- For servers, also expose Prometheus metrics (counters, gauges, histograms) on a standard scrape endpoint.

## Maintenance

- Keep this file current with key decisions and workflows. Update it in the same change that a decision or workflow changes.
