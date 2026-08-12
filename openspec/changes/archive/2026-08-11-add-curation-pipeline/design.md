## Context

`curation` currently has only the server bedrock (archived `add-server`): a
running `std.http.Server` with config loading (`host`/`port`/`auth_token` via
`std.json`, XDG path, `--config`/env overrides), `/healthz`, an unused bearer
auth gate, structured logging, and `/metrics`. Nothing processes content yet.
`.see/intent.md` fixes the curation pipeline order as normalize → dedupe →
filter → tag → cap → longevity evaluation → route → store (FR-5), and states
the pipeline *minus evaluation* is "pure and deterministic" (intent §2, §7;
US-003: "Rule application is pure/deterministic; a unit test asserts given
input → expected curated output").

This change lands that pure, deterministic core and nothing more. It is the
smallest slice that is fully testable in isolation: the pipeline takes a slice
of input items and the configured rules and returns curated items, with no
network, filesystem, or subprocess access. Fetching (US-002/008, which carries
the genuine RSS/Atom XML-parser risk of intent §7), longevity evaluation
(US-009, the only non-deterministic step), storage (FR-6), and EPUB/download
(US-004) are each later changes that feed into or out of this transform.

## Goals / Non-Goals

**Goals:**
- An item model: input `Item` (title, url, body, date, source) and output
  `CuratedItem` (same fields + an ordered, de-duplicated tag set).
- A pure pipeline `curate(allocator, items, rules) → []CuratedItem` applying
  normalize → dedupe → filter → tag → cap, deterministic for identical inputs.
- Conservative URL normalization (lowercase scheme/host, drop fragment, drop
  trailing slash; keep query) with a normalized-title-hash fallback for empty
  URLs; first-occurrence-wins dedupe preserving order.
- Case-insensitive substring include/exclude filter rules and tag rules, plus a
  per-run cap.
- Rule config (`filter_rules`, `tag_rules`, `cap`) as optional fields in the
  existing JSON config, decoded by the existing `std.json` loader.

**Non-Goals:**
- Fetching anything — feed parsing (US-002), the RSS/Atom XML tokenizer
  (intent §7 tech risk), and Lightpanda web rendering (US-008) are later
  changes. This pipeline is fed synthetic `Item`s in tests.
- Longevity classification and news/knowledge routing (US-009) — the pipeline
  ends at cap; it does not label or split streams.
- Persistence (FR-6 JSONL store), the daily schedule, `POST /curate`,
  EPUB generation, and `/download` (US-004) — all later.
- Any config-loading *behavior* change: the server loader already ignores
  unknown fields, so adding recognized fields needs no change to loading. No
  modification to the `server` spec.
- Glob/regex/boolean rule expressions: substring only this change.

## Decisions

### D1. Pipeline as one pure allocator-taking function
`pub fn curate(allocator, items: []const Item, rules: Rules) ![]CuratedItem`.
No globals, no I/O, no logging, no time. Output is a freshly allocated slice
the caller frees. Determinism follows for free from "no inputs but the
arguments."
- *Alternative:* a streaming iterator. Rejected — adds state for no gain at
  this volume (a daily digest is tens to low hundreds of items); a slice is
  simpler to test and compose.

### D2. Conservative URL normalization + title-hash fallback
Normalize a non-empty URL with `std.Uri`/manual parse: lowercase scheme and
host (hosts are case-insensitive), drop the `#fragment`, drop one trailing
slash from the path; **keep the query** (tracking-param stripping risks
collapsing distinct items). Dedupe key = the normalized URL. For an empty URL,
key = a hex digest of the trimmed, lowercased title via
`std.crypto.hash.sha2.Sha256` truncated to 128 bits — stable and collision-safe
at digest scale.
- *Alternative:* drop query, or parse known trackers. Rejected as v1 — too
  aggressive; collapses distinct items. Keep the ceiling explicit.
- `// ponytail: no query/tracker normalization; add a known-tracker strip list
  if duplicate-via-tracker noise appears in real feeds.`

### D3. Substring matching, case-insensitive, on title and/or URL
Each rule carries a target set (title, url, or both) and a needle; a match is
`std.ascii.indexOfIgnoreCase` (≠ -1) on each requested target (a rule matches
if *any* of its requested targets contains the needle). This is the "simple
pattern" of intent US-003, scoped to substring — the boring, debuggable choice.
- *Alternative:* glob/regex. Rejected for v1 — substring covers the noise-free
  cases; regex pulls in a parser for little gain.
- `// ponytail: substring match only; add glob if operators need wildcards.`

### D4. Rule precedence: include gate, then exclude, both before tag, cap last
Stage order per FR-5: filter (include/exclude) runs before tag, cap runs last.
Within filter: if include rules exist, an item must match ≥1 include (deny by
default); an empty include list means allow-all. Then any matching exclude rule
drops the item. Tagging reads only survivors, so a filtered item is never tagged
(spec scenario). This is the standard, least-surprising interpretation.
- *Alternative:* exclude-wins-by-precedence over include. Considered and
  rejected semantics — order is "include gate, then exclude," documented in the
  spec; revisit only if an operator finds it surprising.

### D5. Tags as an ordered, de-duplicated set
A curated item's tags are appended in first-match order and de-duplicated by
exact name (case-sensitive), so repeated matches never duplicate a tag. A small
linear scan dedupes — fine at tag-per-item scale.
- `// ponytail: O(tags²) per-item dedupe; trivial at this scale; only revisit
  if rule counts grow large.`

### D6. Rule config as optional struct fields, decoded by the existing loader
Add `filter_rules`, `tag_rules`, `cap` to the `Config` struct. `std.json`
parse into a struct already ignores unknown fields (forward compatibility, per
the `server` spec) and treats absent fields via struct defaults (empty lists,
zero cap ⇒ unbounded). No loader rewrite; the curation capability owns the
*shape* of these fields, the server capability owns the *mechanism*.
- *Alternative:* a nested `curation: {…}` object. Rejected for v1 — flattening
  is one less level of config indirection; nest later if rule groups multiply.

## Risks / Trade-offs

- **[Over-aggressive normalization collapses distinct items]** → Mitigation:
  conservative normalization (D2): keep the query, only canonicalize case and
  fragment/trailing slash; ceiling noted.
- **[Substring matching too coarse / false matches]** → Mitigation: scope to
  substring, case-insensitive, explicit target set (D3); glob/regex is a later
  ceiling, not a v1 cut.
- **[Deny-by-default include rules surprise operators]** → Mitigation:
  documented explicitly in the spec (no include rules ⇒ allow-all); the
  default config has no include rules, so the default is pass-through.
- **[Empty-URL title-hash collisions]** → Mitigation: SHA-256-truncated digest
  is collision-safe at digest scale; distinct titles hash distinctly by design.
- **[Rule config shape churn]** → Mitigation: keep the v1 shape minimal and
  flat (D6); the loader's unknown-field tolerance absorbs later additions.

## Migration Plan

Greenfield and additive — no migration. Deploy by: add optional
`filter_rules`/`tag_rules`/`cap` to `config.json` (all optional; omitting them
is pass-through). No store, endpoint, or runtime behavior changes in this cut
(the server keeps serving the placeholder `/`). Rollback is `git revert`; the
new code is exercised only by `zig build test` and not yet wired into any
request path.

## Open Questions

- None blocking. The exact tag *ordering* (first-match vs. sorted) is fixed as
  first-match in D5; it can be refined in review without re-scoping. Tracker
  query-param stripping (D2 ceiling) is deliberately deferred.
