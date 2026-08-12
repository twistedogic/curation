// RSS/Atom feed parser: pure, I/O-free, tolerant extraction of items.
// ponytail: RSS/Atom-subset scanner, not a general XML parser; switch to a
// vendored tokenizer if malformed/namespace-heavy feeds in the wild defeat it.
const std = @import("std");

const item_mod = @import("item.zig");
pub const Item = item_mod.Item;

pub fn parseFeed(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    source: []const u8,
) std.mem.Allocator.Error![]Item {
    var out: std.ArrayList(Item) = .empty;
    errdefer {
        for (out.items) |it| freeItem(gpa, it);
        out.deinit(gpa);
    }
    if (isAtom(bytes)) {
        try parseBlocks(gpa, bytes, "entry", source, extractAtomEntry, &out);
    } else {
        try parseBlocks(gpa, bytes, "item", source, extractRssItem, &out);
    }
    return out.toOwnedSlice(gpa);
}

/// Free a slice returned by `parseFeed`. Safe on an empty slice.
pub fn freeParsed(gpa: std.mem.Allocator, items: []Item) void {
    for (items) |it| freeItem(gpa, it);
    gpa.free(items);
}

fn freeItem(gpa: std.mem.Allocator, it: Item) void {
    gpa.free(it.title);
    gpa.free(it.url);
    gpa.free(it.body);
    gpa.free(it.date);
    // `source` is aliased from the caller's input and not freed here.
}

fn isAtom(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const lt = std.mem.indexOfScalarPos(u8, bytes, i, '<') orelse return false;
        if (startsWithAt(bytes, lt, "<?xml")) {
            const close = std.mem.indexOfPos(u8, bytes, lt, "?>") orelse return false;
            i = close + 2;
            continue;
        }
        if (startsWithAt(bytes, lt, "<!DOCTYPE")) {
            const close = std.mem.indexOfPos(u8, bytes, lt, ">") orelse return false;
            i = close + 1;
            continue;
        }
        if (startsWithAt(bytes, lt, "<!--")) {
            const close = std.mem.indexOfPos(u8, bytes, lt, "-->") orelse return false;
            i = close + 3;
            continue;
        }
        return startsWithAt(bytes, lt, "<feed");
    }
    return false;
}

fn startsWithAt(bytes: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > bytes.len) return false;
    return std.mem.eql(u8, bytes[pos..][0..needle.len], needle);
}

fn parseBlocks(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    tag: []const u8,
    source: []const u8,
    extract: *const fn (gpa: std.mem.Allocator, body: []const u8, source: []const u8) std.mem.Allocator.Error!Item,
    out: *std.ArrayList(Item),
) std.mem.Allocator.Error!void {
    var pos: usize = 0;
    while (true) {
        const block = nextBlock(bytes, pos, tag) orelse break;
        defer pos = block.end;
        const it = try extract(gpa, block.body, source);
        errdefer freeItem(gpa, it);
        try out.append(gpa, it);
    }
}

const Block = struct { body: []const u8, end: usize };

fn nextBlock(bytes: []const u8, from: usize, tag: []const u8) ?Block {
    const start = indexOfOpenTag(bytes, from, tag) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, bytes, start, '>') orelse return null;
    const body_start = gt + 1;
    const end_open = indexOfCloseTag(bytes, body_start, tag) orelse return null;
    return .{
        .body = bytes[body_start..end_open],
        .end = end_open + (tag.len + 3), // "</" + tag + ">"
    };
}

fn indexOfOpenTag(bytes: []const u8, from: usize, tag: []const u8) ?usize {
    var i = from;
    while (i + tag.len + 1 < bytes.len) {
        if (bytes[i] == '<' and std.mem.eql(u8, bytes[i + 1 ..][0..tag.len], tag)) {
            const after = i + 1 + tag.len;
            // Next byte must be whitespace, '>', or '/'.
            if (after < bytes.len and (bytes[after] == '>' or bytes[after] == '/' or std.ascii.isWhitespace(bytes[after]))) {
                return i;
            }
        }
        i += 1;
    }
    return null;
}

fn indexOfCloseTag(bytes: []const u8, from: usize, tag: []const u8) ?usize {
    var i = from;
    while (i + tag.len + 3 <= bytes.len) {
        if (bytes[i] == '<' and bytes[i + 1] == '/' and
            std.mem.eql(u8, bytes[i + 2 ..][0..tag.len], tag) and
            bytes[i + 2 + tag.len] == '>')
        {
            return i;
        }
        i += 1;
    }
    return null;
}

fn extractRssItem(
    gpa: std.mem.Allocator,
    body: []const u8,
    source: []const u8,
) std.mem.Allocator.Error!Item {
    const link_text = extractTagText(body, "link") orelse "";
    const body_text = extractTagText(body, "description") orelse "";
    const date_text = extractTagText(body, "pubDate") orelse "";
    return extractItem(gpa, body, link_text, body_text, date_text, source);
}

fn extractAtomEntry(
    gpa: std.mem.Allocator,
    body: []const u8,
    source: []const u8,
) std.mem.Allocator.Error!Item {
    const link_text = extractAtomLinkHref(body);
    const body_text = extractTagText(body, "summary") orelse extractTagText(body, "content") orelse "";
    const date_text = extractTagText(body, "updated") orelse extractTagText(body, "published") orelse "";
    return extractItem(gpa, body, link_text, body_text, date_text, source);
}

fn extractItem(
    gpa: std.mem.Allocator,
    body: []const u8,
    link_text: []const u8,
    body_text: []const u8,
    date_text: []const u8,
    source: []const u8,
) std.mem.Allocator.Error!Item {
    const title = try decodeField(gpa, body, "title");
    errdefer gpa.free(title);
    const url = try extractTextField(gpa, link_text);
    errdefer gpa.free(url);
    const decoded_body = try decodeBodyField(gpa, body_text);
    errdefer gpa.free(decoded_body);
    const date = try extractTextField(gpa, date_text);
    errdefer gpa.free(date);
    return .{
        .title = title,
        .url = url,
        .body = decoded_body,
        .date = date,
        .source = source,
    };
}

fn decodeBodyField(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const inner = unwrapCdata(raw) orelse raw;
    return decodeAlloc(gpa, trimWhitespace(inner));
}

/// Extract and trim a plain-text field (url, date). Returns "" for malformed
/// fields (text containing `<`, which indicates an unclosed/broken tag).
fn extractTextField(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    if (hasUnbalancedMarkup(raw)) return gpa.dupe(u8, "");
    return gpa.dupe(u8, trimWhitespace(raw));
}

fn extractTagText(body: []const u8, tag: []const u8) ?[]const u8 {
    const block = nextBlock(body, 0, tag) orelse return null;
    return block.body;
}

fn extractAtomLinkHref(body: []const u8) []const u8 {
    var pos: usize = 0;
    while (pos < body.len) {
        const lt = std.mem.indexOfScalarPos(u8, body, pos, '<') orelse return "";
        const lt_end = std.mem.indexOfScalarPos(u8, body, lt, '>') orelse return "";
        const tag = body[lt..lt_end];
        if (std.mem.startsWith(u8, tag, "<link")) {
            if (extractAttr(tag, "href")) |href| return href;
        }
        pos = lt_end + 1;
    }
    return "";
}

pub fn extractAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + name.len + 1 < tag.len) {
        if (std.mem.eql(u8, tag[i..][0..name.len], name) and tag[i + name.len] == '=') {
            const vstart = i + name.len + 1;
            if (vstart >= tag.len) return null;
            const quote = tag[vstart];
            if (quote != '"' and quote != '\'') return null;
            const value_start = vstart + 1;
            const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
            return tag[value_start..value_end];
        }
        i += 1;
    }
    return null;
}

fn decodeField(gpa: std.mem.Allocator, body: []const u8, tag: []const u8) std.mem.Allocator.Error![]u8 {
    const raw = extractTagText(body, tag) orelse return gpa.dupe(u8, "");
    if (unwrapCdata(raw)) |inner| return decodeAlloc(gpa, trimWhitespace(inner));
    // Non-CDATA: any `<` indicates an unclosed/broken tag — treat as malformed.
    if (hasUnbalancedMarkup(raw)) return gpa.dupe(u8, "");
    return decodeAlloc(gpa, trimWhitespace(raw));
}

fn unwrapCdata(s: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, "<![CDATA[")) return null;
    if (!std.mem.endsWith(u8, s, "]]>")) return null;
    return s["<![CDATA[".len .. s.len - "]]>".len];
}

fn hasUnbalancedMarkup(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '<') != null;
}

fn decodeAlloc(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            if (try decodeEntity(gpa, raw, &i, &out)) continue;
        }
        try out.append(gpa, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn decodeEntity(gpa: std.mem.Allocator, raw: []const u8, i: *usize, out: *std.ArrayList(u8)) std.mem.Allocator.Error!bool {
    // On entry, raw[i.*] == '&'. On success, advances past the entity and
    // returns true. On a malformed/unknown entity, leaves i unchanged and
    // returns false (caller then writes '&' literally).
    const start = i.*;
    const semi = std.mem.indexOfScalarPos(u8, raw, start, ';') orelse return false;
    if (semi - start > 10) return false;
    const ent = raw[start + 1 .. semi];
    if (std.mem.eql(u8, ent, "amp")) {
        try out.append(gpa, '&');
    } else if (std.mem.eql(u8, ent, "lt")) {
        try out.append(gpa, '<');
    } else if (std.mem.eql(u8, ent, "gt")) {
        try out.append(gpa, '>');
    } else if (std.mem.eql(u8, ent, "quot")) {
        try out.append(gpa, '"');
    } else if (std.mem.eql(u8, ent, "apos")) {
        try out.append(gpa, '\'');
    } else if (ent.len > 2 and ent[0] == '#') {
        const code = std.fmt.parseInt(u21, ent[1..], 10) catch
            std.fmt.parseInt(u21, ent[2..], 16) catch return false;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(code, &buf) catch return false;
        try out.appendSlice(gpa, buf[0..len]);
    } else return false;
    i.* = semi + 1;
    return true;
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and std.ascii.isWhitespace(s[start])) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and std.ascii.isWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

// ============= tests =============

const test_rss_two_items: []const u8 =
    "<?xml version=\"1.0\"?>\n" ++
    "<rss version=\"2.0\">\n" ++
    "  <channel>\n" ++
    "    <title>Sample Feed</title>\n" ++
    "    <item>\n" ++
    "      <title>First Post</title>\n" ++
    "      <link>https://example.com/first</link>\n" ++
    "      <description>First body.</description>\n" ++
    "      <pubDate>Mon, 06 Jan 2025 12:00:00 GMT</pubDate>\n" ++
    "    </item>\n" ++
    "    <item>\n" ++
    "      <title>Second Post</title>\n" ++
    "      <link>https://example.com/second</link>\n" ++
    "      <description>Second body.</description>\n" ++
    "      <pubDate>Tue, 07 Jan 2025 12:00:00 GMT</pubDate>\n" ++
    "    </item>\n" ++
    "  </channel>\n" ++
    "</rss>\n"
;

const test_atom_one_entry: []const u8 =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" ++
    "<feed xmlns=\"http://www.w3.org/2005/Atom\">\n" ++
    "  <title>Atom Sample</title>\n" ++
    "  <entry>\n" ++
    "    <title>Hello Atom</title>\n" ++
    "    <link href=\"https://example.com/hello\"/>\n" ++
    "    <summary>An Atom entry summary.</summary>\n" ++
    "    <updated>2025-01-08T10:00:00Z</updated>\n" ++
    "  </entry>\n" ++
    "</feed>\n"
;

const test_cdata_entity: []const u8 =
    "<?xml version=\"1.0\"?>\n" ++
    "<rss version=\"2.0\">\n" ++
    "  <channel>\n" ++
    "    <item>\n" ++
    "      <title>CDATA &amp; entity</title>\n" ++
    "      <link>https://example.com/c</link>\n" ++
    "      <description><![CDATA[ A &amp; B ]]></description>\n" ++
    "      <pubDate>Wed, 08 Jan 2025 00:00:00 GMT</pubDate>\n" ++
    "    </item>\n" ++
    "  </channel>\n" ++
    "</rss>\n"
;

const test_missing_link: []const u8 =
    "<?xml version=\"1.0\"?>\n" ++
    "<rss version=\"2.0\">\n" ++
    "  <channel>\n" ++
    "    <item>\n" ++
    "      <title>Title Only</title>\n" ++
    "      <description>No link here.</description>\n" ++
    "    </item>\n" ++
    "  </channel>\n" ++
    "</rss>\n"
;

const test_malformed_then_ok: []const u8 =
    "<?xml version=\"1.0\"?>\n" ++
    "<rss version=\"2.0\">\n" ++
    "  <channel>\n" ++
    "    <item>\n" ++
    "      <title>First With Bad Date</title>\n" ++
    "      <link>https://example.com/bad</link>\n" ++
    "      <description>First body.</description>\n" ++
    "      <pubDate><broken & no close</pubDate>\n" ++
    "    </item>\n" ++
    "    <item>\n" ++
    "      <title>Second Is Fine</title>\n" ++
    "      <link>https://example.com/fine</link>\n" ++
    "      <description>Second body.</description>\n" ++
    "      <pubDate>Thu, 09 Jan 2025 00:00:00 GMT</pubDate>\n" ++
    "    </item>\n" ++
    "  </channel>\n" ++
    "</rss>\n"
;

test "parseFeed: RSS 2.0 with two items extracts both in document order" {
    const gpa = std.testing.allocator;
    const items = try parseFeed(gpa, test_rss_two_items, "example");
    defer freeParsed(gpa, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("First Post", items[0].title);
    try std.testing.expectEqualStrings("https://example.com/first", items[0].url);
    try std.testing.expectEqualStrings("First body.", items[0].body);
    try std.testing.expectEqualStrings("Mon, 06 Jan 2025 12:00:00 GMT", items[0].date);
    try std.testing.expectEqualStrings("example", items[0].source);
    try std.testing.expectEqualStrings("Second Post", items[1].title);
    try std.testing.expectEqualStrings("https://example.com/second", items[1].url);
}

test "parseFeed: Atom entry extracts url, body, date from entry elements" {
    const gpa = std.testing.allocator;
    const items = try parseFeed(gpa, test_atom_one_entry, "atom-feed");
    defer freeParsed(gpa, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Hello Atom", items[0].title);
    try std.testing.expectEqualStrings("https://example.com/hello", items[0].url);
    try std.testing.expectEqualStrings("An Atom entry summary.", items[0].body);
    try std.testing.expectEqualStrings("2025-01-08T10:00:00Z", items[0].date);
    try std.testing.expectEqualStrings("atom-feed", items[0].source);
}

test "parseFeed: CDATA wrapper and named entity are decoded" {
    const gpa = std.testing.allocator;
    const items = try parseFeed(gpa, test_cdata_entity, "cdata");
    defer freeParsed(gpa, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("A & B", items[0].body);
    try std.testing.expectEqualStrings("CDATA & entity", items[0].title);
}

test "parseFeed: missing link yields empty url, item otherwise valid" {
    const gpa = std.testing.allocator;
    const items = try parseFeed(gpa, test_missing_link, "nope");
    defer freeParsed(gpa, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Title Only", items[0].title);
    try std.testing.expectEqualStrings("", items[0].url);
    try std.testing.expectEqualStrings("No link here.", items[0].body);
}

test "parseFeed: malformed element does not abort later items" {
    const gpa = std.testing.allocator;
    const items = try parseFeed(gpa, test_malformed_then_ok, "mix");
    defer freeParsed(gpa, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("First With Bad Date", items[0].title);
    try std.testing.expectEqualStrings("", items[0].date);
    try std.testing.expectEqualStrings("Second Is Fine", items[1].title);
    try std.testing.expectEqualStrings("Thu, 09 Jan 2025 00:00:00 GMT", items[1].date);
}

test "parseFeed: identical bytes yield identical output across runs" {
    const gpa = std.testing.allocator;
    const a = try parseFeed(gpa, test_rss_two_items, "example");
    defer freeParsed(gpa, a);
    const b = try parseFeed(gpa, test_rss_two_items, "example");
    defer freeParsed(gpa, b);
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try std.testing.expectEqualStrings(x.title, y.title);
        try std.testing.expectEqualStrings(x.url, y.url);
        try std.testing.expectEqualStrings(x.body, y.body);
        try std.testing.expectEqualStrings(x.date, y.date);
        try std.testing.expectEqualStrings(x.source, y.source);
    }
}