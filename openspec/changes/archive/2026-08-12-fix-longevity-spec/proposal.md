## Why

After twelve archived changes, `curation`'s acquire → curate → classify →
store → serve pipeline is fully built and `zig build test` is green. Every
capability named in `.see/intent.md` has a merged specification under
`openspec/specs/` — structurally, every one except `longevity`.
`openspec/specs/longevity/spec.md` does not begin with
`# longevity Specification`; it begins with `## ADDED Requirements`, the header
that is valid only *inside* a change's delta file. When `add-longevity-evaluator`
was archived, the canonical merged-spec document shell (the
`# <capability> Specification` title, the `## Purpose` section, and the
`## Requirements` section header) was never generated; the change-delta body was
written verbatim into the main spec's place.

The consequence is not cosmetic. `openspec validate longevity --type spec` fails,
`openspec list --specs` reports `longevity requirements 0` (against the six
well-formed requirements actually present in the file), and — critically —
`openspec archive` of any change that touches the `longevity` capability now
aborts with *"target spec is structurally invalid and cannot be updated until
fixed … Aborted. No files were changed."* The `longevity` capability is therefore
frozen: it cannot be evolved through OpenSpec until the document is repaired.
That blocks the very next slice the prior change (`add-curation-metrics`) tee'd
up — threading the `pi`-evaluation count/latency/failures metric into the
longevity seam to finish closing intent **US-006**, which that change explicitly
deferred as *"the obvious next slice."*

This change is the smallest one that unfreezes it: restore the canonical document
structure around the six existing, already-correct requirements, and add a guard
so a malformed merged spec fails the build instead of silently landing again. No
requirement content, no scenario, and no Zig source file changes; `zig build test`
stays green. It is a bug fix in the spec-tooling layer, reproduced before the fix
(`openspec validate longevity` is red today) with a regression test (the new
`validate` guard) — exactly the discipline `AGENTS.md` requires.

## What Changes

- **Repair `openspec/specs/longevity/spec.md`** into the canonical merged-spec
  shape the other eight capabilities use: a `# longevity Specification` title, a
  `## Purpose` paragraph, and a `## Requirements` section, with the six existing
  requirements (Label-to-kind mapping, Longevity classification, Strict label
  parsing, Failure tolerance, Evaluation cache, Evaluation configuration) and all
  their scenarios preserved verbatim. Requirement and scenario text is unchanged;
  only the document shell is restored.
- Because the target main spec is structurally invalid, `openspec archive`
  cannot merge a delta onto it (it aborts). The repair is therefore a **direct
  document rewrite**, and the change is archived with `--skip-specs` — the
  OpenSpec path for doc-only / tooling changes — so the archive step moves the
  change into `archive/` without re-touching the already-corrected main spec. The
  change still carries a `longevity` delta recording the canonical requirement
  set, so `openspec validate fix-longevity-spec` passes and the repaired spec's
  intended contents are explicit and reviewable.
- **Add a regression guard** so this exact regression is caught automatically: a
  `validate` task in `Taskfile.yml` running `openspec validate --specs`, wired
  into CI as its own job. The repository is already OpenSpec-managed (the
  `openspec/` tree and `openspec/config.yaml` are checked in), so OpenSpec is
  existing project tooling, not a new product dependency. After this change
  `openspec validate --specs` is green across all nine capabilities and fails
  loudly if a main spec ever carries a delta header again.
- Standard library only for the product; `zig build test` stays green. No Zig
  source, no store, no config, no EPUB, no route, and no requirement-content
  change.

## Capabilities

### Modified Capabilities
- `longevity`: no requirement is added, removed, or reworded. The merged
  specification document is restored to canonical structure
  (`# longevity Specification` / `## Purpose` / `## Requirements`) so that
  `openspec validate longevity --type spec` passes, `openspec list --specs`
  reports its six requirements, and `openspec archive` can evolve the capability
  again. The six requirements and every `#### Scenario:` block are preserved
  verbatim.

## Impact

- **Specs:** `openspec/specs/longevity/spec.md` is rewritten into canonical
  merged-spec form (document shell restored; six requirements and all scenarios
  preserved verbatim). This is the only spec change. The eight other main specs
  are untouched.
- **Code:** none. No `.zig` file changes. The product is unaffected; the defect
  lives entirely in the spec-tooling layer.
- **Automation:** `Taskfile.yml` gains a `validate` target
  (`openspec validate --specs`); `.github/workflows/ci.yml` gains a small `specs`
  job (Node setup + `openspec validate --specs`) so a malformed merged spec fails
  CI. `task build` and `task test` are unchanged and stay green.
- **Dependencies:** none added to the product. OpenSpec is already the project's
  spec tooling; CI gains a Node setup step to *run* it, not a product dependency.
  `zig build`/`zig build test` are unaffected.
- **Process:** unblocks the next longevity-modifying change (the deferred
  `pi`-evaluation metrics slice of US-006). No stored item, token, EPUB, auth, or
  config contract changes.
