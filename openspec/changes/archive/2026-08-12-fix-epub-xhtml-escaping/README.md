# fix-epub-xhtml-escaping

Correctness fix (intent G4): the EPUB builder emits each record's `title` and `body` raw into the XHTML content documents and the navigation link text, so any `&`, `<`, `>`, `"`, or `'` in fetched content produces malformed XHTML and an EPUB that may fail to open on an e-reader. XML-escape record text at every emission point and extend the `zig build test` EPUB self-check to assert it.
