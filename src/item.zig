// Item model: input and output records for the curation pipeline.
// ponytail: plain values, no I/O; the pipeline owns state.
const std = @import("std");

/// Input record feeding the pipeline. Fields are slices; the pipeline aliases
/// them onto the output `CuratedItem` rather than copying.
pub const Item = struct {
    title: []const u8,
    url: []const u8,
    body: []const u8,
    date: []const u8,
    source: []const u8,
};

/// Output record from the pipeline. Carries every input field plus the set of
/// tag names the pipeline assigned. Tags are owned by the slice; the caller
/// frees them via `freeCurated` (see curation.zig).
pub const CuratedItem = struct {
    title: []const u8,
    url: []const u8,
    body: []const u8,
    date: []const u8,
    source: []const u8,
    tags: []const []const u8,
};

// ============= tests =============

test "Item carries the five required fields" {
    const item = Item{
        .title = "T",
        .url = "U",
        .body = "B",
        .date = "D",
        .source = "S",
    };
    try std.testing.expectEqualStrings("T", item.title);
    try std.testing.expectEqualStrings("U", item.url);
    try std.testing.expectEqualStrings("B", item.body);
    try std.testing.expectEqualStrings("D", item.date);
    try std.testing.expectEqualStrings("S", item.source);
}

test "CuratedItem preserves input fields and exposes tags" {
    const item = CuratedItem{
        .title = "T",
        .url = "U",
        .body = "B",
        .date = "D",
        .source = "S",
        .tags = &.{ "a", "b" },
    };
    try std.testing.expectEqualStrings("T", item.title);
    try std.testing.expectEqualStrings("U", item.url);
    try std.testing.expectEqualStrings("B", item.body);
    try std.testing.expectEqualStrings("D", item.date);
    try std.testing.expectEqualStrings("S", item.source);
    try std.testing.expectEqual(@as(usize, 2), item.tags.len);
    try std.testing.expectEqualStrings("a", item.tags[0]);
    try std.testing.expectEqualStrings("b", item.tags[1]);
}

test "Item with empty url is a valid pipeline input" {
    const item = Item{
        .title = "Hello",
        .url = "",
        .body = "",
        .date = "",
        .source = "s",
    };
    try std.testing.expectEqualStrings("", item.url);
    // Spec: empty URL falls back to title hash for dedupe; covered by
    // curation.zig's "empty URL falls back to title hash" test.
}
