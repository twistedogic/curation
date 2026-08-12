// Curation pipeline: normalize → dedupe → filter → tag → cap.
// ponytail: substring match only, no query/tracker stripping, no regex,
// no glob; bounded by config size and daily volume. Each stage is a small
// pure function so the whole pipeline is a pure function of (items, rules).
const std = @import("std");

const item_mod = @import("item.zig");
const config_mod = @import("config.zig");

pub const Item = item_mod.Item;
pub const CuratedItem = item_mod.CuratedItem;
pub const Rules = config_mod.Rules;
pub const FilterRule = config_mod.FilterRule;
pub const TagRule = config_mod.TagRule;
pub const Target = config_mod.Target;
pub const Action = config_mod.Action;

/// Apply the curation pipeline to an item slice. Returns a freshly allocated
/// slice of `CuratedItem`; the caller frees it with `freeCurated`.
///
/// The five input string fields are aliased from the input items — the caller
/// must keep `items` alive for the lifetime of the output. Tag strings are
/// owned by the output slice.
pub fn curate(
    gpa: std.mem.Allocator,
    items: []const Item,
    rules: Rules,
) std.mem.Allocator.Error![]CuratedItem {
    var seen: std.ArrayList([]u8) = .empty;
    defer {
        for (seen.items) |k| gpa.free(k);
        seen.deinit(gpa);
    }
    var out: std.ArrayList(CuratedItem) = .empty;
    defer out.deinit(gpa); // no-op after toOwnedSlice
    errdefer freeCuratedItems(gpa, out.items);
    // normalize → dedupe → filter → tag → cap, all in one pass. Once the cap
    // is hit nothing past it can affect the output, so we bail.
    for (items) |it| {
        const key = try dedupeKey(gpa, it);
        if (containsKey(seen.items, key)) {
            gpa.free(key);
            continue;
        }
        try seen.append(gpa, key);
        if (!passesFilter(it, rules.filter_rules)) continue;
        if (rules.cap != 0 and out.items.len >= rules.cap) break;
        const tags = try collectTags(gpa, it, rules.tag_rules);
        try out.append(gpa, .{
            .title = it.title,
            .url = it.url,
            .body = it.body,
            .date = it.date,
            .source = it.source,
            .tags = tags,
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Free a curated slice returned by `curate`. Safe to call on an empty slice.
pub fn freeCurated(gpa: std.mem.Allocator, items: []CuratedItem) void {
    freeCuratedItems(gpa, items);
    if (items.len > 0) gpa.free(items);
}

fn freeCuratedItems(gpa: std.mem.Allocator, items: []CuratedItem) void {
    for (items) |ci| {
        for (ci.tags) |t| gpa.free(t);
        if (ci.tags.len > 0) gpa.free(ci.tags);
    }
}

// ---- normalization ----

fn isSchemeChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.';
}

/// Normalize a URL the same way the curation pipeline does for dedupe
/// (lowercase scheme and host, drop the fragment, strip the trailing slash).
/// Empty input returns an empty slice verbatim. Exposed so the OPML-import
/// merge and the curation pipeline agree on "same source" (design D3).
pub fn normalizeUrl(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    if (raw.len == 0) return gpa.dupe(u8, "");
    // Drop fragment.
    const no_frag = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;

    // Identify scheme (RFC 3986: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )).
    var scheme_end: usize = 0;
    while (scheme_end < no_frag.len and isSchemeChar(no_frag[scheme_end])) : (scheme_end += 1) {}
    const has_scheme = scheme_end > 0 and scheme_end < no_frag.len and no_frag[scheme_end] == ':';

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (!has_scheme) {
        // No scheme: pass through with case preserved, drop trailing slash.
        try appendPathNoTrail(gpa, &out, no_frag);
        return out.toOwnedSlice(gpa);
    }

    // Lowercase scheme.
    try out.appendSlice(gpa, no_frag[0..scheme_end]);
    _ = std.ascii.lowerString(out.items[0..scheme_end], out.items[0..scheme_end]);
    try out.append(gpa, ':');

    var rest_start = scheme_end + 1;
    const has_authority = rest_start + 1 < no_frag.len and
        no_frag[rest_start] == '/' and no_frag[rest_start + 1] == '/';
    if (has_authority) {
        try out.appendSlice(gpa, "//");
        rest_start += 2;
        // Find host end (start of '/' or '?').
        var host_end = rest_start;
        while (host_end < no_frag.len and no_frag[host_end] != '/' and no_frag[host_end] != '?') : (host_end += 1) {}
        const host = no_frag[rest_start..host_end];
        const host_lower = try gpa.dupe(u8, host);
        defer gpa.free(host_lower);
        _ = std.ascii.lowerString(host_lower, host_lower);
        try out.appendSlice(gpa, host_lower);
        if (host_end < no_frag.len) try appendPathNoTrail(gpa, &out, no_frag[host_end..]);
    } else {
        try appendPathNoTrail(gpa, &out, no_frag[rest_start..]);
    }
    return out.toOwnedSlice(gpa);
}

fn appendPathNoTrail(gpa: std.mem.Allocator, out: *std.ArrayList(u8), segment: []const u8) std.mem.Allocator.Error!void {
    if (segment.len == 0) return;
    // Drop exactly one trailing slash (does not produce a path of "").
    const end = if (segment[segment.len - 1] == '/') segment.len - 1 else segment.len;
    if (end == 0) return;
    try out.appendSlice(gpa, segment[0..end]);
}

fn titleNormalizedKey(gpa: std.mem.Allocator, title: []const u8) std.mem.Allocator.Error![]u8 {
    // Trim ASCII whitespace, lowercase, then SHA-256 truncated to 128 bits.
    var start: usize = 0;
    while (start < title.len and std.ascii.isWhitespace(title[start])) : (start += 1) {}
    var end: usize = title.len;
    while (end > start and std.ascii.isWhitespace(title[end - 1])) : (end -= 1) {}
    const trimmed = title[start..end];
    const lower = try gpa.alloc(u8, trimmed.len);
    defer gpa.free(lower);
    _ = std.ascii.lowerString(lower, trimmed);

    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lower, &hash, .{});
    const hex_len = 16; // 128 bits = 32 hex chars
    var hex_buf: [hex_len * 2 + 2]u8 = undefined; // "t:" + 32 hex chars
    const out = std.fmt.bufPrint(&hex_buf, "t:{x}", .{hash[0..hex_len]}) catch unreachable;
    return gpa.dupe(u8, out);
}

fn dedupeKey(gpa: std.mem.Allocator, it: Item) std.mem.Allocator.Error![]u8 {
    if (it.url.len == 0) return titleNormalizedKey(gpa, it.title);
    const norm = try normalizeUrl(gpa, it.url);
    errdefer gpa.free(norm);
    const prefix = try gpa.alloc(u8, norm.len + 2);
    @memcpy(prefix[2..], norm);
    prefix[0] = 'u';
    prefix[1] = ':';
    gpa.free(norm);
    return prefix;
}

fn containsKey(seen: []const []u8, key: []const u8) bool {
    for (seen) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

// ---- filter ----

fn passesFilter(it: Item, rules: []const FilterRule) bool {
    var has_include = false;
    var matched_include = false;
    for (rules) |r| {
        if (r.action == .include) {
            has_include = true;
            if (!matched_include and ruleMatches(r.target, it, r.needle)) matched_include = true;
        }
    }
    if (has_include and !matched_include) return false;
    for (rules) |r| {
        if (r.action == .exclude and ruleMatches(r.target, it, r.needle)) return false;
    }
    return true;
}

fn ruleMatches(target: Target, it: Item, needle: []const u8) bool {
    return switch (target) {
        .title => std.ascii.indexOfIgnoreCase(it.title, needle) != null,
        .url => std.ascii.indexOfIgnoreCase(it.url, needle) != null,
        .any => std.ascii.indexOfIgnoreCase(it.title, needle) != null or
            std.ascii.indexOfIgnoreCase(it.url, needle) != null,
    };
}

// ---- tag ----

fn collectTags(gpa: std.mem.Allocator, it: Item, rules: []const TagRule) std.mem.Allocator.Error![]const []u8 {
    var out: std.ArrayList([]u8) = .empty;
    defer out.deinit(gpa);
    for (rules) |r| {
        if (!ruleMatches(r.target, it, r.needle)) continue;
        if (hasTag(out.items, r.tag)) continue;
        try out.append(gpa, try gpa.dupe(u8, r.tag));
    }
    return out.toOwnedSlice(gpa);
}

fn hasTag(seen: []const []u8, tag: []const u8) bool {
    // ponytail: O(tags²) per-item dedupe; trivial at this scale; only revisit
    // if rule counts grow large.
    for (seen) |t| if (std.mem.eql(u8, t, tag)) return true;
    return false;
}

// ============= tests =============

const TestItem = struct {
    title: []const u8,
    url: []const u8 = "",
    body: []const u8 = "",
    date: []const u8 = "",
    source: []const u8 = "test",
};

fn itemsFrom(arena: std.mem.Allocator, ts: []const TestItem) ![]Item {
    const out = try arena.alloc(Item, ts.len);
    for (ts, 0..) |t, i| {
        out[i] = .{
            .title = t.title,
            .url = t.url,
            .body = t.body,
            .date = t.date,
            .source = t.source,
        };
    }
    return out;
}

fn expectNames(got: []CuratedItem, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, 0..) |name, i| {
        try std.testing.expectEqualStrings(name, got[i].title);
    }
}

// ---- normalization & dedupe ----

test "curate: same URL differing only in case and fragment dedupes" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "A", .url = "HTTPS://Example.COM/a#frag" },
        .{ .title = "B", .url = "https://example.com/a" },
    });
    const out = try curate(gpa, items, .{});
    defer freeCurated(gpa, out);
    try expectNames(out, &.{"A"});
}

test "curate: trailing slash is ignored for dedupe" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "A", .url = "https://example.com/a/" },
        .{ .title = "B", .url = "https://example.com/a" },
    });
    const out = try curate(gpa, items, .{});
    defer freeCurated(gpa, out);
    try expectNames(out, &.{"A"});
}

test "curate: distinct query strings are not deduped" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "A", .url = "https://example.com/a?x=1" },
        .{ .title = "B", .url = "https://example.com/a?x=2" },
    });
    const out = try curate(gpa, items, .{});
    defer freeCurated(gpa, out);
    try expectNames(out, &.{ "A", "B" });
}

test "curate: empty URL falls back to title hash" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "Hello", .url = "" },
        .{ .title = "  hello  ", .url = "" },
        .{ .title = "Other", .url = "" },
    });
    const out = try curate(gpa, items, .{});
    defer freeCurated(gpa, out);
    try expectNames(out, &.{ "Hello", "Other" });
}

// ---- filter rules ----

test "curate: exclude substring drops matching items" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "Acme — Sponsored Post" },
        .{ .title = "Real Article" },
    });
    const rules: Rules = .{
        .filter_rules = &.{
            .{ .action = .exclude, .target = .title, .needle = "sponsored" },
        },
    };
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    try expectNames(out, &.{"Real Article"});
}

test "curate: include rules are deny-by-default" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "Rust release", .url = "https://example.com/r" },
        .{ .title = "News About Cars", .url = "https://example.com/c" },
    });
    const rules: Rules = .{
        .filter_rules = &.{
            .{ .action = .include, .target = .title, .needle = "rust" },
        },
    };
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    try expectNames(out, &.{"Rust release"});
}

test "curate: no include rules allows every item" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "A" },
        .{ .title = "B" },
    });
    const rules: Rules = .{};
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    try expectNames(out, &.{ "A", "B" });
}

test "curate: matching is case-insensitive" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "this is spam" },
        .{ .title = "fine article" },
    });
    const rules: Rules = .{
        .filter_rules = &.{
            .{ .action = .exclude, .target = .title, .needle = "SPAM" },
        },
    };
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    try expectNames(out, &.{"fine article"});
}

// ---- tag rules ----

test "curate: a match assigns the tag" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "New LLM benchmark" },
        .{ .title = "Other news" },
    });
    const rules: Rules = .{
        .tag_rules = &.{
            .{ .tag = "ai", .target = .title, .needle = "llm" },
        },
    };
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(usize, 1), out[0].tags.len);
    try std.testing.expectEqualStrings("ai", out[0].tags[0]);
    try std.testing.expectEqual(@as(usize, 0), out[1].tags.len);
}

test "curate: repeated matches do not duplicate a tag" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "LLM benchmark" },
    });
    const rules: Rules = .{
        .tag_rules = &.{
            .{ .tag = "ai", .target = .title, .needle = "llm" },
            .{ .tag = "ai", .target = .title, .needle = "benchmark" },
        },
    };
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(usize, 1), out[0].tags.len);
    try std.testing.expectEqualStrings("ai", out[0].tags[0]);
}

test "curate: filtered-out items are never tagged" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "LLM spam" },
        .{ .title = "LLM real" },
    });
    const rules: Rules = .{
        .filter_rules = &.{
            .{ .action = .exclude, .target = .title, .needle = "spam" },
        },
        .tag_rules = &.{
            .{ .tag = "ai", .target = .title, .needle = "llm" },
        },
    };
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("LLM real", out[0].title);
    try std.testing.expectEqual(@as(usize, 1), out[0].tags.len);
    try std.testing.expectEqualStrings("ai", out[0].tags[0]);
}

// ---- pipeline / cap ----

test "curate: same inputs yield identical output across two runs" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "A", .url = "http://a" },
        .{ .title = "B", .url = "http://b" },
        .{ .title = "Acme Sponsored", .url = "http://c" },
    });
    const rules: Rules = .{
        .filter_rules = &.{
            .{ .action = .exclude, .target = .title, .needle = "sponsored" },
        },
        .tag_rules = &.{
            .{ .tag = "x", .target = .title, .needle = "a" },
        },
        .cap = 10,
    };
    const out1 = try curate(gpa, items, rules);
    defer freeCurated(gpa, out1);
    const out2 = try curate(gpa, items, rules);
    defer freeCurated(gpa, out2);
    try std.testing.expectEqual(out1.len, out2.len);
    for (out1, out2) |a, b| {
        try std.testing.expectEqualStrings(a.title, b.title);
        try std.testing.expectEqualStrings(a.url, b.url);
        try std.testing.expectEqual(a.tags.len, b.tags.len);
        for (a.tags, b.tags) |ta, tb| try std.testing.expectEqualStrings(ta, tb);
    }
}

test "curate: cap truncates to the limit preserving order" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "A", .url = "http://a" },
        .{ .title = "B", .url = "http://b" },
        .{ .title = "C", .url = "http://c" },
        .{ .title = "D", .url = "http://d" },
        .{ .title = "E", .url = "http://e" },
    });
    const rules: Rules = .{ .cap = 3 };
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    try expectNames(out, &.{ "A", "B", "C" });
}

test "curate: unset cap is unbounded" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "A", .url = "http://a" },
        .{ .title = "B", .url = "http://b" },
        .{ .title = "C", .url = "http://c" },
        .{ .title = "D", .url = "http://d" },
        .{ .title = "E", .url = "http://e" },
    });
    const rules: Rules = .{ .cap = 0 };
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    try expectNames(out, &.{ "A", "B", "C", "D", "E" });
}

test "curate: stages run in defined order (filtered preempts tagged)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try itemsFrom(arena.allocator(), &.{
        .{ .title = "drop me please" },
        .{ .title = "keep me" },
    });
    const rules: Rules = .{
        .filter_rules = &.{
            .{ .action = .exclude, .target = .title, .needle = "drop" },
        },
        .tag_rules = &.{
            .{ .tag = "tag-for-drop", .target = .title, .needle = "drop" },
            .{ .tag = "tag-for-keep", .target = .title, .needle = "keep" },
        },
    };
    const out = try curate(gpa, items, rules);
    defer freeCurated(gpa, out);
    // Only "keep me" survives, and only its tag is present.
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("keep me", out[0].title);
    try std.testing.expectEqual(@as(usize, 1), out[0].tags.len);
    try std.testing.expectEqualStrings("tag-for-keep", out[0].tags[0]);
}
