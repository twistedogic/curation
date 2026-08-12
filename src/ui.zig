// Embedded single-page download UI.
//
// ponytail: tiny module — page bytes + content self-checks only; no HTTP,
// no EPUB, no token codec, no storage access. Library consumers serve the
// bytes verbatim at GET /.
const std = @import("std");

/// The embedded download page (HTML + inlined CSS + inlined JS). Compiled
/// into the binary at build time via `@embedFile`. Library callers serve
/// these bytes verbatim.
pub const page: []const u8 = @embedFile("ui.html");

// ============= content self-checks =============
//
// These pin the page's contract statically so a regression in the asset
// fails `zig build test` rather than landing a page that violates the
// spec (external requests, wrong affordance count, etc).

test "ui: page has no external <script src=...> element" {
    try std.testing.expect(std.mem.indexOf(u8, page, "<script src") == null);
}

test "ui: page has no external <link rel=\"stylesheet\" href=...> element" {
    try std.testing.expect(std.mem.indexOf(u8, page, "<link rel=\"stylesheet\" href") == null);
}

test "ui: page has no attribute value containing ://" {
    try std.testing.expect(std.mem.indexOf(u8, page, "://") == null);
}

test "ui: page renders exactly two download affordances, one per kind (news, knowledge)" {
    // Each affordance is identified by data-kind="<kind>" on its button.
    try std.testing.expect(std.mem.indexOf(u8, page, "data-kind=\"news\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-kind=\"knowledge\"") != null);

    // Exactly two affordances total, no third kind.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, page, idx, "data-kind=")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
