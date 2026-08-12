# add-curation-metrics

US-006 observability (partial): expose the curation-run domain metrics — runs, items fetched, items curated per kind (news/knowledge), source fetch errors, and items pruned — on `/metrics`, recorded by the curation job from its run summary through the existing server metrics registry. EPUB-generation and `pi`-evaluation metrics are deferred to a follow-up.
