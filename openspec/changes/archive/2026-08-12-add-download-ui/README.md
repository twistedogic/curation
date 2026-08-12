# add-download-ui

The embedded single-page download UI (intent US-007): a static HTML/JS/CSS page embedded via `@embedFile` and served open at `GET /`, holding one last-download token per kind plus the bearer token in browser `localStorage` and driving `GET /download` per kind — including the first-download bootstrap (absent `since` + `kind` param) deferred by `add-epub-download`.
