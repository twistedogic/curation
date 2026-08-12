## 1. Label, kind, and mapping

- [x] 1.1 Add `src/longevity.zig` defining `Label` (`short_term`, `long_term`,
  `unknown`) and `Kind` (`news`, `knowledge`); plain value types.
- [x] 1.2 Self-check: short_term→news, long_term→knowledge; `unknown` maps via
  the configured default kind (spec: Label-to-kind mapping).

## 2. Pi-invoker seam

- [x] 2.1 Define an injectable `Invoker` (function pointer/vtable) taking the
  eval config + rendered prompt and returning stdout bytes or an error;
  provide a thin production `std.process.Child` invoker (design D1).
- [x] 2.2 Self-check: a stub invoker returning canned output is exercised; the
  production subprocess path is opt-in/manual, not the default suite.

## 3. Strict parsing and fallback

- [x] 3.1 Implement strict single-token parsing of `short_term`/`long_term`
  from pi stdout (case-insensitive, token-boundary-aware); anything else →
  `unknown` (design D2).
- [x] 3.2 Self-check: `SHORT_TERM`/`long_term` parse; empty, prose, and
  `short-term` (hyphen) yield `unknown`; `unknown` → default kind `news`, and a
  custom `default_kind` is honored (spec: Strict label parsing, Failure
  tolerance).

## 4. SHA-256 cache

- [x] 4.1 Implement the cache keyed on hex SHA-256(title+body), persisted as
  one JSON object at `$XDG_CACHE_HOME/curation/eval-cache.json`, loaded at
  construction, consulted before invoke, written-through only on a successful
  classification (design D4).
- [x] 4.2 Self-check: a cached item is a hit (no invoke); a failed/`unknown`
  classification is not cached and is retried next run; the cache round-trips
  through the JSON file (spec: Evaluation cache).

## 5. Evaluator integration

- [x] 5.1 Implement `classify(allocator, item) -> Kind` running
  cache-lookup → render-prompt → invoke → parse → cache-write → fallback, with
  the failure path logged at WARN and never aborting (design D1/D3/D6).
- [x] 5.2 Self-check: end-to-end with a stub invoker — success caches and
  routes; invoke error → `unknown` → default kind, logged, non-fatal (spec:
  Longevity classification, Failure tolerance).

## 6. Evaluation configuration

- [x] 6.1 Add a nested `pi` config block (`path`, `model`, `prompt`,
  `default_kind`, `timeout_seconds`) to `src/config.zig`, decoded by the
  existing `std.json` loader with documented defaults (design D5/D6, default
  prompt from intent §9).
- [x] 6.2 Self-check: absent `pi` block leaves defaults; unknown fields
  ignored; `default_kind` honored (spec: Evaluation configuration).

## 7. Integration

- [x] 7.1 Register the new module in `main.zig`'s comptime test import block
  so `zig build test` discovers it.
- [x] 7.2 `zig build test` green.
