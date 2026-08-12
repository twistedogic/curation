# add-web-rendering

Web-content acquisition via the Lightpanda headless browser (intent US-008 / FR-14): a `sources`-capability path that renders a web-content URL out-of-process (`lightpanda fetch --dump <markdown|html> <url>`), captures the output as the item body, and feeds the same item model the feed path uses. The curation run acquires configured `web_sources` in addition to feed sources, with per-source error isolation. Adds `web_sources` and a `lightpanda` config block.
