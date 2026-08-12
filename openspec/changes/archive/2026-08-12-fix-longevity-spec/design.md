## Context

`curation` is built one OpenSpec change at a time on the `see` loop. Each cycle
scaffolds a proposal against `.see/intent.md`, then applies it: the apply step
writes code per `tasks.md` and runs `openspec archive`, which moves the change
into `openspec/changes/archive/<date>-<name>/` and merges its spec delta into the
main specs under `openspec/specs/`. Twelve changes have been applied this way;
the product is complete and `zig build test` is green.

Eight of the nine main specs are well-formed canonical documents
(`# <capability> Specification` / `## Purpose` / `## Requirements`, with
`### Requirement:` blocks each carrying `#### Scenario:` blocks). The ninth,
`openspec/specs/longevity/spec.md`, is not: its first line is
`## ADDED Requirements` — a header that OpenSpec parses only *inside* a change's
delta file. Everything else in the file (six well-formed requirements with
scenarios) is correct. So when `add-longevity-evaluator` was archived, the merge
wrote the delta body into the main spec without generating the surrounding
document shell.

This breaks three things, confirmed directly:

1. `openspec validate longevity --type spec` → ✗ ("Main spec contains delta
   header …").
2. `openspec list --specs` → `longevity requirements 0` (the six requirements are
   invisible because they sit outside a `## Requirements` section).
3. `openspec archive <any change touching longevity>` → *"target spec is
   structurally invalid and cannot be updated until fixed … Aborted. No files
   were changed."*

Item 3 is the one that matters going forward: the `longevity` capability is
frozen. The immediately-next intended slice — `add-curation-metrics` deferred the
`pi`-evaluation count/latency/failures metric (US-006) into the longevity seam —
cannot be archived until this is fixed. So this repair is both a standalone
defect fix and a prerequisite.

## Goals / Non-Goals

**Goals:**
- A canonical `openspec/specs/longevity/spec.md` whose document structure matches
  the other eight main specs, with the six existing requirements and every
  scenario preserved verbatim.
- `openspec validate --specs` green across all nine capabilities;
  `openspec list --specs` reports `longevity requirements 6`.
- The `longevity` capability is unfrozen — `openspec archive` can evolve it again.
- A regression guard (`openspec validate --specs` in `Taskfile.yml` and CI) that
  fails if a main spec ever carries a delta header again.
- `openspec validate fix-longevity-spec` passes; `zig build test` stays green.

**Non-Goals:**
- No change to any requirement's text, SHALL clauses, or scenarios — the defect
  is structural, not content. Rewording would re-open already-reviewed acceptance
  criteria and is scope creep.
- No Zig source change; no config, store, token, EPUB, auth, or route change.
- No repair to any other capability — the other eight main specs validate.
- No re-running or rewriting of the original `add-longevity-evaluator` archive.
- No OpenSpec version-pinning or caching polish in CI beyond the minimal setup
  needed to run `validate --specs`; pin a version if reproducibility of the spec
  tool itself ever matters.

## Decisions

### D1 — Direct document rewrite + `openspec archive --skip-specs`, not a normal archive

A normal `openspec archive` merges a change's delta into the target main spec.
Against the malformed `longevity` main spec it aborts (item 3 above; reproduced
empirically). So the repair cannot ride on the merge path. Instead the apply
step rewrites `openspec/specs/longevity/spec.md` directly into canonical form
(prepending the document shell and dropping the stray `## ADDED Requirements`
line), then archives the change with `--skip-specs`, which moves the change to
`archive/` without touching any main spec. This is exactly the OpenSpec-provided
escape hatch for "infrastructure, tooling, or doc-only changes." Verified
end-to-end in a scratch copy: canonical rewrite → `validate --specs` 9/9 green →
`archive --skip-specs` → corrected main spec untouched → final `validate --all`
clean.

### D2 — The change carries a `longevity` delta even though it is not merged

`openspec validate <change>` requires at least one delta, so a delta-less
doc-only change is rejected. The change therefore carries
`specs/longevity/spec.md` under a `## ADDED Requirements` header containing the
six canonical requirements. Because the repair uses `--skip-specs` (D1), this
delta is never merged; it serves as the explicit, reviewable record of what the
repaired main spec must contain, and it is what makes the change itself valid.
`## ADDED` is the accurate header: until the repair lands, OpenSpec parses zero
longevity requirements, so establishing the six is an addition from the tool's
point of view. The design.md and tasks.md pin the delta and the rewritten main
spec to the same six requirements so the two cannot drift.

### D3 — Requirements preserved verbatim

The six requirements and every `#### Scenario:` are copied byte-for-byte; only
the leading `## ADDED Requirements` line is removed and the document shell
(`# longevity Specification` / `## Purpose` / `## Requirements`) is prepended.
Any content edit would be unrequested scope and would silently amend acceptance
criteria the `add-longevity-evaluator` change already settled. The `## Purpose`
paragraph is new prose (the main spec had none), kept consistent with that
change's capability description and the spec's own "Capability boundary"-style
wording.

### D4 — Guard with `openspec validate --specs`, not a hand-rolled structural check

The regression to catch is "a delta header lands in a main spec." `openspec
validate --specs` already detects exactly that (it is how this defect was
found), so a bespoke grep would reinvent the tool. OpenSpec is the project's own
spec tooling, so running it in CI is not a new dependency. A `validate` task
makes it reproducible locally (AGENTS.md §7); a dedicated CI `specs` job enforces
it on every change. The narrowness risk (it catches structural malformation, not
semantic spec quality) is acceptable — structural validity is the regression;
semantic review stays human.

`// ponytail: single `validate` target + one CI job; no per-spec linter or
custom parser. Upgrade to `openspec validate --strict` if tighter scenario
rules are ever wanted.`

## Risks / Trade-offs

- **The change delta is not merged (`--skip-specs`).** The repaired main spec and
  the change's `## ADDED` delta must describe the same six requirements. They are
  pinned together in tasks.md and both covered by `openspec validate`, so drift
  is caught. Flagged explicitly so the non-merge is not mistaken for an oversight.
- **CI gains a Node setup step.** Minor tooling surface in a Zig project,
  justified by the spec-driven (§2.6) and regression-test (`AGENTS.md`) mandates.
  It runs in an isolated `specs` job; the existing build-and-test job is
  unchanged. If CI OpenSpec version drift ever bites, pin the version (Non-Goal).
- **The guard is structural.** `validate --specs` will not catch a *well-formed*
  spec that is merely low-quality; that stays a review concern, not a CI one.
- **Scope is intentionally tiny.** This does not advance a user story by itself;
  its value is restoring correctness and unblocking the next slice. It is the
  smallest change that turns `openspec validate --specs` green and lets
  `longevity` evolve again.
