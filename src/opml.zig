// OPML feed-outline extractor + idempotent merge into config.Source.
// ponytail: substring-scanner ceiling on outline parsing; revisit if a real
// OPML exporter defeats it. No new XML dependency; reuses feed.extractAttr.
const std = @import("std");

const config_mod = @import("config.zig");
const feed_mod = @import("feed.zig");
const curation_mod = @import("curation.zig");

const Source = config_mod.Source;

/// Scan OPML bytes for `<outline ...>` start tags. For each outline that
/// carries an `xmlUrl`, emit a `Source` (url=xmlUrl; name=title|text|url).
/// Outlines without `xmlUrl` are skipped (folders / htmlUrl-only). Nested
/// outlines are not treated as a tree: the walker finds every start tag in
/// document order, so children of a folder contribute their own sources.
/// Malformed outlines (no terminator, no xmlUrl) are skipped silently.
pub fn extractSources(gpa: std.mem.Allocator, opml_bytes: []const u8) std.mem.Allocator.Error![]Source {
    var out: std.ArrayList(Source) = .empty;
    errdefer {
        for (out.items) |s| {
            gpa.free(s.name);
            gpa.free(s.url);
        }
        out.deinit(gpa);
    }
    var pos: usize = 0;
    while (pos < opml_bytes.len) {
        const lt = std.mem.indexOfScalarPos(u8, opml_bytes, pos, '<') orelse break;
        if (!startsWithOutline(opml_bytes, lt)) {
            pos = lt + 1;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, opml_bytes, lt, '>') orelse break;
        if (gt == lt + 1) {
            pos = gt + 1;
            continue;
        }
        const tag = opml_bytes[lt..gt];
        const xml_url = feed_mod.extractAttr(tag, "xmlUrl");
        if (xml_url) |url| {
            const name_raw = feed_mod.extractAttr(tag, "title") orelse
                feed_mod.extractAttr(tag, "text") orelse url;
            const owned_name = try gpa.dupe(u8, name_raw);
            errdefer gpa.free(owned_name);
            const owned_url = try gpa.dupe(u8, url);
            errdefer gpa.free(owned_url);
            try out.append(gpa, .{ .name = owned_name, .url = owned_url });
        }
        pos = gt + 1;
    }
    return out.toOwnedSlice(gpa);
}

fn startsWithOutline(bytes: []const u8, pos: usize) bool {
    // Match `<outline` followed by whitespace, '>', or '/'.
    const needle = "<outline";
    if (pos + needle.len > bytes.len) return false;
    if (!std.mem.eql(u8, bytes[pos..][0..needle.len], needle)) return false;
    if (pos + needle.len >= bytes.len) return true;
    const next = bytes[pos + needle.len];
    return next == '>' or next == '/' or std.ascii.isWhitespace(next);
}

/// Merge `incoming` into `existing`, preserving existing order and appending
/// each incoming source whose normalized url is not already present in
/// (existing ∪ already-appended). Empty urls are kept verbatim and not
/// deduped against anything (two empty-url entries are two distinct sources).
pub fn mergeSources(
    gpa: std.mem.Allocator,
    existing: []const Source,
    incoming: []const Source,
) std.mem.Allocator.Error![]Source {
    var seen: std.ArrayList([]u8) = .empty;
    defer {
        for (seen.items) |k| gpa.free(k);
        seen.deinit(gpa);
    }
    for (existing) |s| try seen.append(gpa, try curation_mod.normalizeUrl(gpa, s.url));

    var out: std.ArrayList(Source) = .empty;
    errdefer {
        for (out.items) |s| {
            gpa.free(s.name);
            gpa.free(s.url);
        }
        out.deinit(gpa);
    }
    for (existing) |s| try out.append(gpa, .{ .name = try gpa.dupe(u8, s.name), .url = try gpa.dupe(u8, s.url) });

    for (incoming) |s| {
        const key = try curation_mod.normalizeUrl(gpa, s.url);
        var dup = false;
        if (key.len > 0) {
            for (seen.items) |k| if (std.mem.eql(u8, k, key)) {
                dup = true;
                break;
            };
        }
        if (dup) {
            gpa.free(key);
            continue;
        }
        // Hand `key` off to `seen` — the inner scope's errdefer only fires
        // if the append fails, so the outer seen-defer owns `key` after.
        {
            errdefer gpa.free(key);
            try seen.append(gpa, key);
        }
        try out.append(gpa, .{ .name = try gpa.dupe(u8, s.name), .url = try gpa.dupe(u8, s.url) });
    }
    return out.toOwnedSlice(gpa);
}

/// Run the import: read `opml_path`, extract its feed outlines, load the
/// configuration at `args_config` (or the resolved XDG/env default if
/// null), merge the outlines into the configuration's `sources`, and
/// atomically rewrite the configuration file. A missing OPML file
/// surfaces as `error.OpmlNotFound` and leaves the configuration
/// untouched.
pub const ImportError = std.Io.Dir.ReadFileAllocError ||
    config_mod.Config.LoadError ||
    config_mod.Config.WriteError ||
    error{ OpmlNotFound };

pub fn importOpml(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    opml_path: []const u8,
    args_config: ?[]const u8,
) ImportError!void {
    const opml_bytes = std.Io.Dir.readFileAlloc(.cwd(), io, opml_path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.OpmlNotFound,
        else => return err,
    };
    defer gpa.free(opml_bytes);

    const incoming = try extractSources(gpa, opml_bytes);
    defer config_mod.freeSources(gpa, incoming);

    const cfg_path = try config_mod.Config.resolvePath(gpa, environ_map, args_config);
    defer gpa.free(cfg_path);

    var cfg = try config_mod.Config.load(gpa, io, environ_map, args_config);

    const old_sources = cfg.sources;
    const merged = mergeSources(gpa, old_sources, incoming) catch |err| {
        cfg.deinit(gpa);
        return err;
    };
    // Reassign cfg.sources to the merged slice; cfg.deinit will then free
    // `merged` (the merged sources) but not the original `old_sources`
    // backing memory, so we free that explicitly after deinit.
    cfg.sources = merged;

    try config_mod.Config.write(gpa, io, cfg, cfg_path);

    cfg.deinit(gpa);
    config_mod.freeSources(gpa, old_sources);
}

const test_opml_two_feeds: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<opml version="2.0">
    \\  <head><title>Sample</title></head>
    \\  <body>
    \\    <outline title="First" xmlUrl="https://example.com/a" type="rss"/>
    \\    <outline title="Second" xmlUrl="https://example.com/b" type="rss"/>
    \\  </body>
    \\</opml>
;

const test_opml_nested_folder: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<opml version="2.0">
    \\  <head><title>Sample</title></head>
    \\  <body>
    \\    <outline title="Tech" text="Tech">
    \\      <outline title="HN" xmlUrl="https://news.ycombinator.com/rss" type="rss"/>
    \\      <outline title="Lobsters" xmlUrl="https://lobste.rs/rss" type="rss"/>
    \\    </outline>
    \\    <outline title="News" xmlUrl="https://example.com/c" type="rss"/>
    \\  </body>
    \\</opml>
;

const test_opml_html_url_only: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<opml version="2.0">
    \\  <head><title>Sample</title></head>
    \\  <body>
    \\    <outline title="Blog" htmlUrl="https://example.com/blog"/>
    \\    <outline title="Feed" xmlUrl="https://example.com/feed" type="rss"/>
    \\  </body>
    \\</opml>
;

const test_opml_paired_outline: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<opml version="2.0">
    \\  <head><title>Sample</title></head>
    \\  <body>
    \\    <outline title="Paired" xmlUrl="https://example.com/p">
    \\      <outline title="Child" xmlUrl="https://example.com/child"/>
    \\    </outline>
    \\  </body>
    \\</opml>
;

const test_opml_text_fallback: []const u8 =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<opml version="2.0">
    \\  <head><title>Sample</title></head>
    \\  <body>
    \\    <outline text="ByText" xmlUrl="https://example.com/text"/>
    \\    <outline xmlUrl="https://example.com/urlonly"/>
    \\  </body>
    \\</opml>
;

test "extractSources: OPML 2.0 yields feed outlines in document order" {
    const gpa = std.testing.allocator;
    const sources = try extractSources(gpa, test_opml_two_feeds);
    defer config_mod.freeSources(gpa, sources);
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("First", sources[0].name);
    try std.testing.expectEqualStrings("https://example.com/a", sources[0].url);
    try std.testing.expectEqualStrings("Second", sources[1].name);
    try std.testing.expectEqualStrings("https://example.com/b", sources[1].url);
}

test "extractSources: nested folders are traversed, not imported" {
    const gpa = std.testing.allocator;
    const sources = try extractSources(gpa, test_opml_nested_folder);
    defer config_mod.freeSources(gpa, sources);
    try std.testing.expectEqual(@as(usize, 3), sources.len);
    try std.testing.expectEqualStrings("HN", sources[0].name);
    try std.testing.expectEqualStrings("https://news.ycombinator.com/rss", sources[0].url);
    try std.testing.expectEqualStrings("Lobsters", sources[1].name);
    try std.testing.expectEqualStrings("https://lobste.rs/rss", sources[1].url);
    try std.testing.expectEqualStrings("News", sources[2].name);
    try std.testing.expectEqualStrings("https://example.com/c", sources[2].url);
}

test "extractSources: outline without xmlUrl is skipped" {
    const gpa = std.testing.allocator;
    const sources = try extractSources(gpa, test_opml_html_url_only);
    defer config_mod.freeSources(gpa, sources);
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqualStrings("Feed", sources[0].name);
    try std.testing.expectEqualStrings("https://example.com/feed", sources[0].url);
}

test "extractSources: paired (non-self-closing) outlines with nested children are both extracted" {
    const gpa = std.testing.allocator;
    const sources = try extractSources(gpa, test_opml_paired_outline);
    defer config_mod.freeSources(gpa, sources);
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("Paired", sources[0].name);
    try std.testing.expectEqualStrings("https://example.com/p", sources[0].url);
    try std.testing.expectEqualStrings("Child", sources[1].name);
    try std.testing.expectEqualStrings("https://example.com/child", sources[1].url);
}

test "extractSources: name falls back to text, then to url" {
    const gpa = std.testing.allocator;
    const sources = try extractSources(gpa, test_opml_text_fallback);
    defer config_mod.freeSources(gpa, sources);
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("ByText", sources[0].name);
    try std.testing.expectEqualStrings("https://example.com/text", sources[0].url);
    try std.testing.expectEqualStrings("https://example.com/urlonly", sources[1].name);
}

test "extractSources: identical bytes yield identical output across runs" {
    const gpa = std.testing.allocator;
    const a = try extractSources(gpa, test_opml_two_feeds);
    defer config_mod.freeSources(gpa, a);
    const b = try extractSources(gpa, test_opml_two_feeds);
    defer config_mod.freeSources(gpa, b);
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try std.testing.expectEqualStrings(x.name, y.name);
        try std.testing.expectEqualStrings(x.url, y.url);
    }
}

const TestSource = struct { name: []const u8, url: []const u8 };

fn ownedSources(gpa: std.mem.Allocator, ts: []const TestSource) ![]Source {
    const out = try gpa.alloc(Source, ts.len);
    for (ts, 0..) |t, i| {
        out[i] = .{ .name = try gpa.dupe(u8, t.name), .url = try gpa.dupe(u8, t.url) };
    }
    return out;
}

test "mergeSources: empty existing gets all incoming in document order" {
    const gpa = std.testing.allocator;
    const existing = try ownedSources(gpa, &.{});
    defer config_mod.freeSources(gpa, existing);
    const incoming = try ownedSources(gpa, &.{
        .{ .name = "A", .url = "https://a.example" },
        .{ .name = "B", .url = "https://b.example" },
    });
    defer config_mod.freeSources(gpa, incoming);

    const merged = try mergeSources(gpa, existing, incoming);
    defer config_mod.freeSources(gpa, merged);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqualStrings("A", merged[0].name);
    try std.testing.expectEqualStrings("https://a.example", merged[0].url);
    try std.testing.expectEqualStrings("B", merged[1].name);
    try std.testing.expectEqualStrings("https://b.example", merged[1].url);
}

test "mergeSources: existing order and identity are preserved" {
    const gpa = std.testing.allocator;
    const existing = try ownedSources(gpa, &.{
        .{ .name = "S1", .url = "https://one.example" },
        .{ .name = "S2", .url = "https://two.example" },
    });
    defer config_mod.freeSources(gpa, existing);
    const incoming = try ownedSources(gpa, &.{
        .{ .name = "S3", .url = "https://three.example" },
    });
    defer config_mod.freeSources(gpa, incoming);

    const merged = try mergeSources(gpa, existing, incoming);
    defer config_mod.freeSources(gpa, merged);
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("S1", merged[0].name);
    try std.testing.expectEqualStrings("S2", merged[1].name);
    try std.testing.expectEqualStrings("S3", merged[2].name);
}

test "mergeSources: URL differing only by case/fragment/trailing-slash is deduped" {
    const gpa = std.testing.allocator;
    const existing = try ownedSources(gpa, &.{
        .{ .name = "S1", .url = "https://example.com/feed" },
    });
    defer config_mod.freeSources(gpa, existing);
    const incoming = try ownedSources(gpa, &.{
        .{ .name = "dup1", .url = "HTTPS://EXAMPLE.com/feed#frag" },
        .{ .name = "dup2", .url = "https://example.com/feed/" },
    });
    defer config_mod.freeSources(gpa, incoming);

    const merged = try mergeSources(gpa, existing, incoming);
    defer config_mod.freeSources(gpa, merged);
    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqualStrings("S1", merged[0].name);
}

test "mergeSources: re-importing the same OPML is a no-op" {
    const gpa = std.testing.allocator;
    const opml =
        \\<opml version="2.0"><head/><body>
        \\<outline title="A" xmlUrl="https://a.example"/>
        \\<outline title="B" xmlUrl="https://b.example"/>
        \\</body></opml>
    ;
    const incoming = try extractSources(gpa, opml);
    defer config_mod.freeSources(gpa, incoming);

    const merged1 = try mergeSources(gpa, &.{}, incoming);
    defer config_mod.freeSources(gpa, merged1);
    const merged2 = try mergeSources(gpa, merged1, incoming);
    defer config_mod.freeSources(gpa, merged2);
    try std.testing.expectEqual(merged1.len, merged2.len);
    for (merged1, merged2) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualStrings(a.url, b.url);
    }
}

test "mergeSources: empty-url incoming is kept verbatim and not deduped" {
    const gpa = std.testing.allocator;
    const existing = try ownedSources(gpa, &.{});
    defer config_mod.freeSources(gpa, existing);
    const incoming = try ownedSources(gpa, &.{
        .{ .name = "noUrl1", .url = "" },
        .{ .name = "noUrl2", .url = "" },
    });
    defer config_mod.freeSources(gpa, incoming);

    const merged = try mergeSources(gpa, existing, incoming);
    defer config_mod.freeSources(gpa, merged);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqualStrings("", merged[0].url);
    try std.testing.expectEqualStrings("", merged[1].url);
}

test "mergeSources: incoming new url is appended after dedupe" {
    const gpa = std.testing.allocator;
    const existing = try ownedSources(gpa, &.{
        .{ .name = "S1", .url = "https://a.example" },
        .{ .name = "dupA", .url = "https://a.example/" },
    });
    defer config_mod.freeSources(gpa, existing);
    const incoming = try ownedSources(gpa, &.{
        .{ .name = "newA", .url = "https://a.example/#frag" },
        .{ .name = "newB", .url = "https://b.example" },
    });
    defer config_mod.freeSources(gpa, incoming);

    const merged = try mergeSources(gpa, existing, incoming);
    defer config_mod.freeSources(gpa, merged);
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("S1", merged[0].name);
    try std.testing.expectEqualStrings("dupA", merged[1].name);
    try std.testing.expectEqualStrings("newB", merged[2].name);
}

test "importOpml: rewrites sources and preserves every other field" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const cfg_path = "zig-cache/tmp/opml-import-cfg.json";
    const opml_path = "zig-cache/tmp/opml-import-feeds.opml";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, cfg_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"tok",
            \\ "filter_rules":[{"action":"exclude","target":"title","needle":"sponsored"}],
            \\ "cap":7,"retention_days":30,
            \\ "sources":[{"name":"hn","url":"https://news.ycombinator.com/rss"}],
            \\ "schedule":"06:30"}
        );
    }
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, opml_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<opml version="2.0">
            \\  <head><title>X</title></head>
            \\  <body>
            \\    <outline title="Lobsters" xmlUrl="https://lobste.rs/rss" type="rss"/>
            \\    <outline title="RSS" xmlUrl="https://example.com/rss" type="rss"/>
            \\  </body>
            \\</opml>
        );
    }
    defer {
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, cfg_path) catch {};
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, opml_path) catch {};
    }

    try importOpml(gpa, std.testing.io, &env, opml_path, cfg_path);

    var reloaded = try config_mod.Config.load(gpa, std.testing.io, &env, cfg_path);
    defer reloaded.deinit(gpa);
    try std.testing.expectEqualStrings("127.0.0.1", reloaded.host);
    try std.testing.expectEqualStrings("tok", reloaded.auth_token);
    try std.testing.expectEqual(@as(usize, 1), reloaded.filter_rules.len);
    try std.testing.expectEqualStrings("sponsored", reloaded.filter_rules[0].needle);
    try std.testing.expectEqual(@as(u32, 7), reloaded.cap);
    try std.testing.expectEqual(@as(u32, 30), reloaded.retention_days);
    try std.testing.expectEqualStrings("06:30", reloaded.schedule);
    try std.testing.expectEqual(@as(usize, 3), reloaded.sources.len);
    try std.testing.expectEqualStrings("hn", reloaded.sources[0].name);
    try std.testing.expectEqualStrings("Lobsters", reloaded.sources[1].name);
    try std.testing.expectEqualStrings("RSS", reloaded.sources[2].name);
}

test "importOpml: a missing OPML file errors and leaves the config untouched" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const cfg_path = "zig-cache/tmp/opml-import-cfg-missing.json";
    const opml_path = "zig-cache/tmp/opml-import-does-not-exist.opml";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    const original_bytes: []const u8 =
        \\{"host":"127.0.0.1","port":8787,"auth_token":"orig",
        \\ "sources":[{"name":"hn","url":"https://news.ycombinator.com/rss"}]}
    ;
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, cfg_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, original_bytes);
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, cfg_path) catch {};

    try std.testing.expectError(error.OpmlNotFound, importOpml(gpa, std.testing.io, &env, opml_path, cfg_path));

    // Verify config is byte-for-byte unchanged.
    const post_bytes = std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, cfg_path, gpa, .unlimited) catch unreachable;
    defer gpa.free(post_bytes);
    try std.testing.expectEqualStrings(original_bytes, post_bytes);
}

test "importOpml: re-running on the same OPML is idempotent on sources" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const cfg_path = "zig-cache/tmp/opml-import-cfg-idem.json";
    const opml_path = "zig-cache/tmp/opml-import-feeds-idem.opml";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, cfg_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"\"}");
    }
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, opml_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\<opml version="2.0"><head/><body>
            \\<outline title="A" xmlUrl="https://a.example"/>
            \\<outline title="B" xmlUrl="https://b.example"/>
            \\</body></opml>
        );
    }
    defer {
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, cfg_path) catch {};
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, opml_path) catch {};
    }

    try importOpml(gpa, std.testing.io, &env, opml_path, cfg_path);
    try importOpml(gpa, std.testing.io, &env, opml_path, cfg_path);

    var reloaded = try config_mod.Config.load(gpa, std.testing.io, &env, cfg_path);
    defer reloaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), reloaded.sources.len);
    try std.testing.expectEqualStrings("A", reloaded.sources[0].name);
    try std.testing.expectEqualStrings("B", reloaded.sources[1].name);
}
