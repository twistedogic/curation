## 1. Restore the longevity merged spec (longevity capability)

- [ ] 1.1 **Reproduce first.** Before any edit, confirm the defect:
  `openspec validate longevity --type spec` fails ("Main spec contains delta
  header …"), and `openspec list --specs` reports `longevity requirements 0`.
  Record both as the failing baseline (design D1; spec: all six longevity
  requirements are currently invisible to the tool).
- [ ] 1.2 Rewrite `openspec/specs/longevity/spec.md` into canonical merged-spec
  form: replace the leading `## ADDED Requirements` line with the document shell
  —
  `# longevity Specification`, blank line, `## Purpose`, the Purpose paragraph
  (see 1.3), blank line, `## Requirements` — and keep every existing requirement
  (Label-to-kind mapping, Longevity classification, Strict label parsing, Failure
  tolerance, Evaluation cache, Evaluation configuration) and every
  `#### Scenario:` block beneath it byte-for-byte. Add no requirement; change no
  requirement or scenario text (design D3; spec: the six longevity requirements,
  restored to visibility).
- [ ] 1.3 The `## Purpose` paragraph (new prose; the main spec had none),
  consistent with the capability boundary and `add-longevity-evaluator`:
  > The pi-based longevity evaluator — the only non-deterministic stage of the
  > curation pipeline. Given a curated item's title and body, it produces a
  > stream kind (`news`/`knowledge`) by wrapping the local `pi` agent CLI,
  > caching successful classifications on SHA-256(title+body), and degrading to a
  > configured-default kind on any failure. curation holds no provider, model, or
  > API-key configuration; `pi` owns all credentials and routing. The evaluator
  > owns the label-to-kind mapping, the strict `pi`-result parser, the evaluation
  > cache, and the evaluation configuration; it performs no HTTP serving, no
  > daily scheduling, and no item storage.
- [ ] 1.4 Verify the six requirements and their scenarios are unchanged: a
  line-by-line diff of the requirements section against the pre-edit file shows
  only the dropped `## ADDED Requirements` line and the prepended shell — no
  `### Requirement:` or `#### Scenario:` text differs (design D3; spec: all six
  longevity requirements).
- [ ] 1.5 No Zig source, config, store, token, or EPUB file is touched; `zig build
  test` stays green.

## 2. Regression guard (automation)

- [ ] 2.1 Add a `validate` task to `Taskfile.yml` that runs
  `openspec validate --specs` (reproducible locally; AGENTS.md §7). It is
  standalone — not chained into `build` or `test` — so a missing OpenSpec install
  never breaks `zig build` (design D4; AGENTS.md §7: never break zig build).
- [ ] 2.2 Add a `specs` job to `.github/workflows/ci.yml`: `checkout`,
  `actions/setup-node@v4`, then
  `npx -y @fission-ai/openspec@latest validate --specs`. It runs on `push`/`pull`
  to `main` like the existing job. The existing `build-and-test` and `publish`
  jobs are unchanged (design D4).
- [ ] 2.3 Confirm the guard catches the regression: temporarily reintroducing a
  `## ADDED Requirements` header (or removing the `## Requirements` section) in
  any `openspec/specs/*/spec.md` makes `task validate` and the CI `specs` job
  fail; reverting makes them pass (design D4; AGENTS.md: never merge a bug fix
  without a regression test).

## 3. Integration / archive

- [ ] 3.1 Before archiving: `openspec validate fix-longevity-spec` is green and
  `openspec validate --specs` is green across all nine capabilities
  (`longevity requirements 6`).
- [ ] 3.2 Archive path for this change is
  `openspec archive fix-longevity-spec --skip-specs --yes` — doc-only: the main
  spec was corrected directly in task 1, so the archive must not re-merge (which
  would otherwise abort on, or duplicate, the now-canonical spec). Verify the
  change moves to `openspec/changes/archive/<date>-fix-longevity-spec/` and the
  corrected `openspec/specs/longevity/spec.md` is left untouched (design D1).
- [ ] 3.3 Final: `zig build test` green; `openspec validate --specs` green (9/9);
  the `longevity` capability is unfrozen (an `openspec archive` dry-run against a
  trivial longevity delta no longer aborts).
