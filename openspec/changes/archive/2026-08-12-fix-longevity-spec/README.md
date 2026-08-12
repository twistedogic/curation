# fix-longevity-spec

Repair the structurally malformed `longevity` merged spec: `openspec/specs/longevity/spec.md` carries a change-delta header (`## ADDED Requirements`) where only a canonical main-spec document (`# longevity Specification` / `## Purpose` / `## Requirements`) is valid, so `openspec validate longevity` fails, requirement counting reports 0, and `openspec archive` aborts on any longevity-touching change. Restores the canonical document shell around the six existing (unchanged) requirements and adds a `validate` task + CI job so the regression is caught automatically.
