// Download engine: kind-scoped token codec, stdlib-only EPUB builder, and
// the incremental resolver. Pure (no HTTP, no scheduling); reads records only
// via the storage capability's range query.
//
// ponytail: hand-written ZIP writer from std.zip header structs +
// std.compress.flate; if Zig adds a std.zip writer, replace the emitter and
// keep the entry set. EPUB emits only EPUB 3 (`nav`); no NCX — older readers
// can be added as a follow-up if a target reader rejects it.
const std = @import("std");

const metrics_mod = @import("metrics.zig");
const store_mod = @import("store.zig");

pub const Kind = store_mod.Kind;
pub const Record = store_mod.Record;
pub const Store = store_mod.Store;

// ============= Token codec =============

pub const TokenError = error{
    InvalidBase64,
    InvalidFormat,
    UnknownKind,
    InvalidId,
};

pub const Token = struct {
    kind: Kind,
    id: u64,
};

/// Encode `kind:id` as standard base64. Caller frees the returned slice.
pub fn encode(gpa: std.mem.Allocator, kind: Kind, id: u64) std.mem.Allocator.Error![]u8 {
    var buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "{s}:{d}", .{ @tagName(kind), id }) catch unreachable;
    const out_len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try gpa.alloc(u8, out_len);
    _ = std.base64.standard.Encoder.encode(out, raw);
    return out;
}

/// Decode a base64 token back to `{ kind, id }`. Any malformed input
/// (non-base64, missing `:`, unknown kind, non-numeric id) fails.
pub fn decode(gpa: std.mem.Allocator, token: []const u8) (std.mem.Allocator.Error || TokenError)!Token {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(token) catch return error.InvalidBase64;
    const buf = try gpa.alloc(u8, decoded_len);
    defer gpa.free(buf);
    std.base64.standard.Decoder.decode(buf, token) catch return error.InvalidBase64;

    const colon = std.mem.indexOfScalar(u8, buf, ':') orelse return error.InvalidFormat;
    const kind_str = buf[0..colon];
    const id_str = buf[colon + 1 ..];

    const kind = std.meta.stringToEnum(Kind, kind_str) orelse return error.UnknownKind;
    if (id_str.len == 0) return error.InvalidId;
    const id = std.fmt.parseInt(u64, id_str, 10) catch return error.InvalidId;
    return .{ .kind = kind, .id = id };
}

// ============= EPUB builder =============

pub const BuildError = std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    std.compress.flate.Decompress.Error ||
    std.Io.Reader.Error ||
    error{ UnsupportedCompressionMethod };

const mime_type_content: []const u8 = "application/epub+zip";
const opf_path: []const u8 = "OEBPS/content.opf";
const nav_path: []const u8 = "OEBPS/nav.xhtml";
const item_prefix: []const u8 = "OEBPS/item";
const item_suffix: []const u8 = ".xhtml";

/// One ZIP entry being assembled into an EPUB.
const ZipSpec = struct {
    name: []const u8,
    method: std.zip.CompressionMethod,
    data: []const u8,
};

/// Build an EPUB in memory from a kind and its records. Caller owns the
/// returned slice and frees it with `gpa`.
pub fn build(gpa: std.mem.Allocator, kind: Kind, records: []const Record) BuildError![]u8 {
    // `owned` keeps alive every heap-allocated slice that `specs` aliases:
    // XML bodies AND dynamic filenames (e.g. OEBPS/item1.xhtml). Static
    // strings (mime_type_content, opf_path, nav_path, "mimetype",
    // "META-INF/container.xml") don't need to live here.
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }

    var specs: std.ArrayList(ZipSpec) = .empty;
    defer specs.deinit(gpa);

    // mimetype: must be first, stored uncompressed.
    try specs.append(gpa, .{ .name = "mimetype", .method = .store, .data = mime_type_content });

    // META-INF/container.xml: points at the OPF.
    const container_xml = try renderContainerXml(gpa);
    try owned.append(gpa, container_xml);
    try specs.append(gpa, .{ .name = "META-INF/container.xml", .method = .deflate, .data = container_xml });

    // OPF: manifest + metadata + spine.
    const opf = try renderOpf(gpa, kind, records);
    try owned.append(gpa, opf);
    try specs.append(gpa, .{ .name = opf_path, .method = .deflate, .data = opf });

    // nav.xhtml: TOC linking to each item.
    const nav = try renderNav(gpa, records);
    try owned.append(gpa, nav);
    try specs.append(gpa, .{ .name = nav_path, .method = .deflate, .data = nav });

    // One XHTML content document per record.
    for (records, 0..) |rec, i| {
        const item_name = try std.fmt.allocPrint(gpa, "{s}{d}{s}", .{ item_prefix, i + 1, item_suffix });
        try owned.append(gpa, item_name);
        const item_doc = try renderItem(gpa, rec);
        try owned.append(gpa, item_doc);
        try specs.append(gpa, .{ .name = item_name, .method = .deflate, .data = item_doc });
    }

    return writeZip(gpa, specs.items);
}

// ---- EPUB content renderers ----

// ponytail: hand-rolled XML escaper (5-char scan); replace with a stdlib
// helper if Zig ever ships one (std.xml). Same shape as the hand-written ZIP
// writer and feed scanner.
fn escapeXml(gpa: std.mem.Allocator, s: []const u8) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    for (s) |b| switch (b) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(b),
    };
    return out.toOwnedSlice();
}

fn renderContainerXml(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa,
        \\<?xml version="1.0"?>
        \\<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        \\  <rootfiles>
        \\    <rootfile full-path="{s}" media-type="application/oebps-package+xml"/>
        \\  </rootfiles>
        \\</container>
        \\
    , .{opf_path});
}

fn renderOpf(gpa: std.mem.Allocator, kind: Kind, records: []const Record) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    const kind_tag = @tagName(kind);
    try w.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        \\  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \\    <dc:identifier id="bookid">urn:uuid:curation-{s}-curation</dc:identifier>
        \\    <dc:title>curation {s}</dc:title>
        \\    <dc:language>en</dc:language>
        \\  </metadata>
        \\  <manifest>
        \\    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \\
    , .{ kind_tag, kind_tag });
    for (records, 0..) |_, i| {
        try w.print("    <item id=\"item{d}\" href=\"item{d}.xhtml\" media-type=\"application/xhtml+xml\"/>\n", .{ i + 1, i + 1 });
    }
    try w.writeAll(
        \\  </manifest>
        \\  <spine>
        \\
    );
    for (records, 0..) |_, i| {
        try w.print("    <itemref idref=\"item{d}\"/>\n", .{i + 1});
    }
    try w.writeAll(
        \\  </spine>
        \\</package>
        \\
    );
    return out.toOwnedSlice();
}

fn renderNav(gpa: std.mem.Allocator, records: []const Record) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        \\<head><title>Table of Contents</title></head>
        \\<body>
        \\<nav epub:type="toc">
        \\<h1>Table of Contents</h1>
        \\<ol>
        \\
    );
    for (records, 0..) |rec, i| {
        const title_esc = try escapeXml(gpa, rec.title);
        defer gpa.free(title_esc);
        try w.print("  <li><a href=\"item{d}.xhtml\">{s}</a></li>\n", .{ i + 1, title_esc });
    }
    try w.writeAll(
        \\</ol>
        \\</nav>
        \\</body>
        \\</html>
        \\
    );
    return out.toOwnedSlice();
}

fn renderItem(gpa: std.mem.Allocator, rec: Record) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    const title_esc = try escapeXml(gpa, rec.title);
    defer gpa.free(title_esc);
    const body_esc = try escapeXml(gpa, rec.body);
    defer gpa.free(body_esc);
    return std.fmt.allocPrint(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<html xmlns="http://www.w3.org/1999/xhtml">
        \\<head><title>{s}</title></head>
        \\<body>
        \\<h1>{s}</h1>
        \\<p>{s}</p>
        \\</body>
        \\</html>
        \\
    , .{ title_esc, title_esc, body_esc });
}

// ---- Minimal ZIP writer (compose std.zip structs) ----

/// Compose a ZIP container from `specs`. Uses `CompressionMethod.store` as-is
/// and DEFLATEs `CompressionMethod.deflate` entries with `std.compress.flate`.
fn writeZip(gpa: std.mem.Allocator, specs: []const ZipSpec) BuildError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    var local_offsets: std.ArrayList(u32) = .empty;
    var crc32s: std.ArrayList(u32) = .empty;
    var compressed_sizes: std.ArrayList(u32) = .empty;
    var uncompressed_sizes: std.ArrayList(u32) = .empty;
    defer {
        local_offsets.deinit(gpa);
        crc32s.deinit(gpa);
        compressed_sizes.deinit(gpa);
        uncompressed_sizes.deinit(gpa);
    }

    var compressed_buffers: std.ArrayList([]u8) = .empty;
    defer {
        for (compressed_buffers.items) |b| gpa.free(b);
        compressed_buffers.deinit(gpa);
    }

    for (specs) |spec| {
        try local_offsets.append(gpa, @intCast(w.buffered().len));
        try crc32s.append(gpa, std.hash.Crc32.hash(spec.data));
        try uncompressed_sizes.append(gpa, @intCast(spec.data.len));

        const body: []u8 = switch (spec.method) {
            .store => try gpa.dupe(u8, spec.data),
            .deflate => try deflateToBuffer(gpa, spec.data),
            else => return error.UnsupportedCompressionMethod,
        };
        try compressed_buffers.append(gpa, body);
        try compressed_sizes.append(gpa, @intCast(body.len));

        const lfh: std.zip.LocalFileHeader = .{
            .signature = std.zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = spec.method,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = crc32s.items[crc32s.items.len - 1],
            .compressed_size = compressed_sizes.items[compressed_sizes.items.len - 1],
            .uncompressed_size = uncompressed_sizes.items[uncompressed_sizes.items.len - 1],
            .filename_len = @intCast(spec.name.len),
            .extra_len = 0,
        };
        try w.writeStruct(lfh, .little);
        try w.writeAll(spec.name);
        try w.writeAll(body);
    }

    // Central directory.
    const cd_offset: u32 = @intCast(w.buffered().len);
    for (specs, 0..) |spec, i| {
        const cdfh: std.zip.CentralDirectoryFileHeader = .{
            .signature = std.zip.central_file_header_sig,
            .version_made_by = 20,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = spec.method,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = crc32s.items[i],
            .compressed_size = compressed_sizes.items[i],
            .uncompressed_size = uncompressed_sizes.items[i],
            .filename_len = @intCast(spec.name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = local_offsets.items[i],
        };
        try w.writeStruct(cdfh, .little);
        try w.writeAll(spec.name);
    }
    const cd_end: u32 = @intCast(w.buffered().len);
    const cd_size: u32 = cd_end - cd_offset;

    // End record.
    const er: std.zip.EndRecord = .{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(specs.len),
        .record_count_total = @intCast(specs.len),
        .central_directory_size = cd_size,
        .central_directory_offset = cd_offset,
        .comment_len = 0,
    };
    try w.writeStruct(er, .little);

    return out.toOwnedSlice();
}

/// DEFLATE `data` into a fresh heap buffer. Uses `flate.max_window_len` of
/// scratch for the compressor's history window.
fn deflateToBuffer(gpa: std.mem.Allocator, data: []const u8) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    // Compress asserts `output.buffer.len > 8`. EnsureUnusedCapacity on a fresh
    // Allocating writer allocates the initial backing storage.
    try aw.ensureUnusedCapacity(flate_writable_scratch);
    var scratch: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&aw.writer, &scratch, .raw, .default);
    try comp.writer.writeAll(data);
    try std.compress.flate.Compress.finish(&comp);
    return aw.toOwnedSlice();
}
const flate_writable_scratch: usize = 64;

// ============= Incremental resolver =============

pub const ResolveResult = struct {
    epub: []u8,
    next_token: []u8,
};

/// Given a decoded token and a store, return the EPUB of the kind's records
/// whose id is strictly greater than `token.id`, plus a next token encoding
/// the last included id. Returns `null` when the range is empty. When
/// `metrics` is non-null, each non-empty resolve records one EPUB generation
/// labeled by the resolved kind; a nothing-new resolve records nothing.
pub fn resolve(
    gpa: std.mem.Allocator,
    store: *Store,
    token: Token,
    metrics: ?*metrics_mod.Metrics,
) BuildError!?ResolveResult {
    const records = try store.range(token.kind, token.id);
    defer gpa.free(records);

    if (records.len == 0) return null;

    const epub = try build(gpa, token.kind, records);
    errdefer gpa.free(epub);

    const last_id = records[records.len - 1].id;
    const next_token = try encode(gpa, token.kind, last_id);

    if (metrics) |m| m.recordEpubGeneration(token.kind);

    return .{ .epub = epub, .next_token = next_token };
}

// ============= Tests =============

test "encode then decode round-trips" {
    const gpa = std.testing.allocator;
    const token = try encode(gpa, .news, 7);
    defer gpa.free(token);
    const decoded = try decode(gpa, token);
    try std.testing.expectEqual(Kind.news, decoded.kind);
    try std.testing.expectEqual(@as(u64, 7), decoded.id);
}

test "decode: malformed token fails" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidBase64, decode(gpa, "not-a-token"));
}

test "decode: unknown kind fails" {
    const gpa = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "sports:3", .{}) catch unreachable;
    const out_len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try gpa.alloc(u8, out_len);
    defer gpa.free(out);
    _ = std.base64.standard.Encoder.encode(out, raw);
    try std.testing.expectError(error.UnknownKind, decode(gpa, out));
}

test "decode: non-numeric id fails" {
    const gpa = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "news:abc", .{}) catch unreachable;
    const out_len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try gpa.alloc(u8, out_len);
    defer gpa.free(out);
    _ = std.base64.standard.Encoder.encode(out, raw);
    try std.testing.expectError(error.InvalidId, decode(gpa, out));
}

test "encode: two kinds encode distinctly" {
    const gpa = std.testing.allocator;
    const news_tok = try encode(gpa, .news, 1);
    defer gpa.free(news_tok);
    const know_tok = try encode(gpa, .knowledge, 1);
    defer gpa.free(know_tok);
    try std.testing.expect(!std.mem.eql(u8, news_tok, know_tok));
    const d_news = try decode(gpa, news_tok);
    const d_know = try decode(gpa, know_tok);
    try std.testing.expectEqual(Kind.news, d_news.kind);
    try std.testing.expectEqual(Kind.knowledge, d_know.kind);
    try std.testing.expectEqual(@as(u64, 1), d_news.id);
    try std.testing.expectEqual(@as(u64, 1), d_know.id);
}

const test_record_a = Record{
    .id = 1,
    .kind = .news,
    .title = "Alpha",
    .url = "",
    .body = "first",
    .date = "",
    .source = "",
    .tags = &.{},
};
const test_record_b = Record{
    .id = 3,
    .kind = .news,
    .title = "Beta",
    .url = "",
    .body = "second",
    .date = "",
    .source = "",
    .tags = &.{},
};

test "build: news kind with two records yields EPUB with mimetype first + stored + correct content" {
    const gpa = std.testing.allocator;
    const records = [_]Record{ test_record_a, test_record_b };
    const epub = try build(gpa, .news, &records);
    defer gpa.free(epub);

    var entries = try readZipEntries(gpa, epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }

    try std.testing.expectEqualStrings("mimetype", entries.items[0].name);
    try std.testing.expectEqual(std.zip.CompressionMethod.store, entries.items[0].method);
    try std.testing.expectEqualStrings(mime_type_content, entries.items[0].data);
}

test "build: same builder builds both kinds" {
    const gpa = std.testing.allocator;
    const news_rec = [_]Record{test_record_a};
    const know_rec = [_]Record{.{ .id = 2, .kind = .knowledge, .title = "K-title", .url = "", .body = "kb", .date = "", .source = "", .tags = &.{} }};

    const news_epub = try build(gpa, .news, &news_rec);
    defer gpa.free(news_epub);
    const know_epub = try build(gpa, .knowledge, &know_rec);
    defer gpa.free(know_epub);

    var news_entries = try readZipEntries(gpa, news_epub);
    defer {
        for (news_entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        news_entries.deinit(gpa);
    }
    var know_entries = try readZipEntries(gpa, know_epub);
    defer {
        for (know_entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        know_entries.deinit(gpa);
    }

    // Each EPUB starts with mimetype.
    try std.testing.expectEqualStrings("mimetype", news_entries.items[0].name);
    try std.testing.expectEqualStrings("mimetype", know_entries.items[0].name);

    // Each EPUB carries its kind's nav links: news nav mentions Alpha, knowledge nav mentions K-title.
    const news_nav = findEntry(news_entries.items, nav_path).?.data;
    const know_nav = findEntry(know_entries.items, nav_path).?.data;
    try std.testing.expect(std.mem.indexOf(u8, news_nav, "Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, news_nav, "K-title") == null);
    try std.testing.expect(std.mem.indexOf(u8, know_nav, "K-title") != null);
    try std.testing.expect(std.mem.indexOf(u8, know_nav, "Alpha") == null);
}

test "build: yields one XHTML document per record" {
    const gpa = std.testing.allocator;
    const records = [_]Record{ test_record_a, test_record_b };
    const epub = try build(gpa, .news, &records);
    defer gpa.free(epub);

    var entries = try readZipEntries(gpa, epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }

    var xhtml_count: usize = 0;
    for (entries.items) |e| {
        if (std.mem.startsWith(u8, e.name, item_prefix) and std.mem.endsWith(u8, e.name, item_suffix)) {
            xhtml_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), xhtml_count);
}

test "build: structural self-check — mimetype, container, OPF manifest, nav" {
    const gpa = std.testing.allocator;
    const records = [_]Record{ test_record_a, test_record_b };
    const epub = try build(gpa, .news, &records);
    defer gpa.free(epub);

    var entries = try readZipEntries(gpa, epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }

    // mimetype first + stored + exact content.
    try std.testing.expectEqualStrings("mimetype", entries.items[0].name);
    try std.testing.expectEqual(std.zip.CompressionMethod.store, entries.items[0].method);
    try std.testing.expectEqualStrings(mime_type_content, entries.items[0].data);

    // container.xml references the OPF.
    const container = findEntry(entries.items, "META-INF/container.xml") orelse return error.MissingContainer;
    try std.testing.expect(std.mem.indexOf(u8, container.data, opf_path) != null);

    // OPF references the nav document + N XHTML content docs.
    const opf = findEntry(entries.items, opf_path) orelse return error.MissingOpf;
    try std.testing.expect(std.mem.indexOf(u8, opf.data, "nav.xhtml") != null);
    try std.testing.expect(std.mem.indexOf(u8, opf.data, "item1.xhtml") != null);
    try std.testing.expect(std.mem.indexOf(u8, opf.data, "item2.xhtml") != null);

    // nav document exists and references both items by title.
    const nav = findEntry(entries.items, nav_path) orelse return error.MissingNav;
    try std.testing.expect(std.mem.indexOf(u8, nav.data, "item1.xhtml") != null);
    try std.testing.expect(std.mem.indexOf(u8, nav.data, "Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, nav.data, "Beta") != null);
}

test "build: hostile record title and body are XML-escaped in the content document" {
    const gpa = std.testing.allocator;
    const hostile = Record{
        .id = 1,
        .kind = .news,
        .title = "A & B < C",
        .url = "",
        .body = "x < y && z > w \"q\" 'r'",
        .date = "",
        .source = "",
        .tags = &.{},
    };
    const records = [_]Record{hostile};
    const epub = try build(gpa, .news, &records);
    defer gpa.free(epub);

    var entries = try readZipEntries(gpa, epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }

    const item = findEntry(entries.items, "OEBPS/item1.xhtml") orelse return error.MissingItem;
    // <head><title> and <h1> escape the title's & and <.
    try std.testing.expect(std.mem.indexOf(u8, item.data, "<title>A &amp; B &lt; C</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.data, "<h1>A &amp; B &lt; C</h1>") != null);
    // <p> escapes all five characters in the body; & is matched first so && → &amp;&amp;.
    try std.testing.expect(std.mem.indexOf(u8, item.data, "<p>x &lt; y &amp;&amp; z &gt; w &quot;q&quot; &#39;r&#39;</p>") != null);
    // The bare record text (with raw & and <) must NOT survive anywhere in the document.
    try std.testing.expect(std.mem.indexOf(u8, item.data, "A & B < C") == null);
    try std.testing.expect(std.mem.indexOf(u8, item.data, "x < y &&") == null);
}

test "build: hostile record title is XML-escaped in the navigation document link text" {
    const gpa = std.testing.allocator;
    const hostile = Record{
        .id = 1,
        .kind = .news,
        .title = "A & B < C",
        .url = "",
        .body = "x < y & z",
        .date = "",
        .source = "",
        .tags = &.{},
    };
    const records = [_]Record{hostile};
    const epub = try build(gpa, .news, &records);
    defer gpa.free(epub);

    var entries = try readZipEntries(gpa, epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }

    const nav = findEntry(entries.items, nav_path) orelse return error.MissingNav;
    // The <a> link text is escaped; the href attribute is the index-derived filename, unchanged.
    try std.testing.expect(std.mem.indexOf(u8, nav.data, "<a href=\"item1.xhtml\">A &amp; B &lt; C</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, nav.data, "A & B < C") == null);
}

test "build: markup-free text is emitted verbatim (no spurious entities)" {
    const gpa = std.testing.allocator;
    const clean = Record{
        .id = 1,
        .kind = .news,
        .title = "Alpha",
        .url = "",
        .body = "first",
        .date = "",
        .source = "",
        .tags = &.{},
    };
    const records = [_]Record{clean};
    const epub = try build(gpa, .news, &records);
    defer gpa.free(epub);

    var entries = try readZipEntries(gpa, epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }

    const item = findEntry(entries.items, "OEBPS/item1.xhtml") orelse return error.MissingItem;
    try std.testing.expect(std.mem.indexOf(u8, item.data, "<title>Alpha</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.data, "<h1>Alpha</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.data, "<p>first</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.data, "&amp;") == null);
    try std.testing.expect(std.mem.indexOf(u8, item.data, "&lt;") == null);
    try std.testing.expect(std.mem.indexOf(u8, item.data, "&gt;") == null);
    try std.testing.expect(std.mem.indexOf(u8, item.data, "&quot;") == null);
    try std.testing.expect(std.mem.indexOf(u8, item.data, "&#39;") == null);
}

// ---- ZIP reader for the self-check (private) ----

const ZipEntry = struct {
    name: []u8,
    method: std.zip.CompressionMethod,
    data: []u8,
};

fn findEntry(entries: []const ZipEntry, name: []const u8) ?ZipEntry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

fn readZipEntries(gpa: std.mem.Allocator, bytes: []const u8) BuildError!std.ArrayList(ZipEntry) {
    var entries: std.ArrayList(ZipEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }

    var pos: usize = 0;
    while (pos + 4 <= bytes.len and
        std.mem.eql(u8, bytes[pos..][0..4], &std.zip.local_file_header_sig))
    {
        const hdr = bytes[pos..][0..@sizeOf(std.zip.LocalFileHeader)];
        const method_raw = std.mem.readInt(u16, hdr[8..10], .little);
        const compressed_size = std.mem.readInt(u32, hdr[18..22], .little);
        const filename_len = std.mem.readInt(u16, hdr[26..28], .little);
        const extra_len = std.mem.readInt(u16, hdr[28..30], .little);

        pos += @sizeOf(std.zip.LocalFileHeader);
        const name = try gpa.dupe(u8, bytes[pos..][0..filename_len]);
        pos += filename_len + extra_len;
        const compressed = bytes[pos..][0..compressed_size];
        pos += compressed_size;

        const data: []u8 = switch (method_raw) {
            0 => try gpa.dupe(u8, compressed),
            8 => try inflateRaw(gpa, compressed),
            else => return error.UnsupportedCompressionMethod,
        };

        try entries.append(gpa, .{
            .name = name,
            .method = if (method_raw == 0) .store else .deflate,
            .data = data,
        });
    }
    return entries;
}

fn inflateRaw(gpa: std.mem.Allocator, compressed: []const u8) BuildError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var reader: std.Io.Reader = .fixed(compressed);
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&reader, .raw, &buf);
    _ = try decomp.reader.streamRemaining(&out.writer);

    return out.toOwnedSlice();
}

// ============= Resolver tests =============

fn makeStoreWithRecords(comptime N: usize, kind_records: [N]struct { kind: Kind, title: []const u8, body: []const u8 }) !Store {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/download-store.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    errdefer store.deinit();

    for (kind_records) |kr| {
        const item: item_mod.CuratedItem = .{
            .title = kr.title,
            .url = "",
            .body = kr.body,
            .date = "",
            .source = "",
            .tags = &.{},
        };
        _ = try store.append(kr.kind, item);
    }
    return store;
}

const item_mod = @import("item.zig");

test "resolve: token {news,1} over news ids [1,3,5] yields EPUB for ids 3,5 and next token {news,5}" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithRecords(5, .{
        .{ .kind = .news, .title = "N1", .body = "" },
        .{ .kind = .knowledge, .title = "K2", .body = "" },
        .{ .kind = .news, .title = "N3", .body = "" },
        .{ .kind = .knowledge, .title = "K4", .body = "" },
        .{ .kind = .news, .title = "N5", .body = "" },
    });
    defer {
        store.deinit();
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, "zig-cache/tmp/download-store.jsonl") catch {};
    }

    const result = try resolve(gpa, &store, .{ .kind = .news, .id = 1 }, null);
    try std.testing.expect(result != null);
    defer {
        gpa.free(result.?.epub);
        gpa.free(result.?.next_token);
    }

    var entries = try readZipEntries(gpa, result.?.epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }

    // Two XHTML docs (N3, N5); no knowledge docs.
    var xhtml_count: usize = 0;
    var has_knowledge_marker: bool = false;
    for (entries.items) |e| {
        if (std.mem.startsWith(u8, e.name, item_prefix) and std.mem.endsWith(u8, e.name, item_suffix)) {
            xhtml_count += 1;
        }
        if (std.mem.indexOf(u8, e.data, "K2") != null or std.mem.indexOf(u8, e.data, "K4") != null) {
            has_knowledge_marker = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), xhtml_count);
    try std.testing.expect(!has_knowledge_marker);

    const next = try decode(gpa, result.?.next_token);
    try std.testing.expectEqual(Kind.news, next.kind);
    try std.testing.expectEqual(@as(u64, 5), next.id);
}

test "resolve: token {news,5} over largest news id 5 signals nothing-new" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithRecords(3, .{
        .{ .kind = .news, .title = "N1", .body = "" },
        .{ .kind = .knowledge, .title = "K2", .body = "" },
        .{ .kind = .news, .title = "N3", .body = "" },
    });
    defer {
        store.deinit();
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, "zig-cache/tmp/download-store.jsonl") catch {};
    }

    // token {news,5}: largest news id is 3, so 3 > 5 is false → nothing-new.
    const result = try resolve(gpa, &store, .{ .kind = .news, .id = 5 }, null);
    try std.testing.expect(result == null);
}

test "resolve: since_id of zero returns all of the kind" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithRecords(5, .{
        .{ .kind = .news, .title = "N1", .body = "" },
        .{ .kind = .knowledge, .title = "K2", .body = "" },
        .{ .kind = .news, .title = "N3", .body = "" },
        .{ .kind = .knowledge, .title = "K4", .body = "" },
        .{ .kind = .news, .title = "N5", .body = "" },
    });
    defer {
        store.deinit();
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, "zig-cache/tmp/download-store.jsonl") catch {};
    }

    const result = try resolve(gpa, &store, .{ .kind = .news, .id = 0 }, null);
    try std.testing.expect(result != null);
    defer {
        gpa.free(result.?.epub);
        gpa.free(result.?.next_token);
    }

    var entries = try readZipEntries(gpa, result.?.epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }
    var xhtml_count: usize = 0;
    for (entries.items) |e| {
        if (std.mem.startsWith(u8, e.name, item_prefix) and std.mem.endsWith(u8, e.name, item_suffix)) {
            xhtml_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), xhtml_count);

    const next = try decode(gpa, result.?.next_token);
    try std.testing.expectEqual(Kind.news, next.kind);
    try std.testing.expectEqual(@as(u64, 5), next.id);
}

test "resolve: delta never overlaps the token" {
    const gpa = std.testing.allocator;
    // Global ids: news(1), knowledge(2), news(3), knowledge(4).
    var store = try makeStoreWithRecords(4, .{
        .{ .kind = .news, .title = "N1", .body = "" },
        .{ .kind = .knowledge, .title = "K2", .body = "" },
        .{ .kind = .news, .title = "N3", .body = "" },
        .{ .kind = .knowledge, .title = "K4", .body = "" },
    });
    defer {
        store.deinit();
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, "zig-cache/tmp/download-store.jsonl") catch {};
    }

    // token {knowledge,2}: half-open range yields only id 4 (K4).
    const result = try resolve(gpa, &store, .{ .kind = .knowledge, .id = 2 }, null);
    try std.testing.expect(result != null);
    defer {
        gpa.free(result.?.epub);
        gpa.free(result.?.next_token);
    }

    var entries = try readZipEntries(gpa, result.?.epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }
    var xhtml_count: usize = 0;
    var has_k2: bool = false;
    for (entries.items) |e| {
        if (std.mem.startsWith(u8, e.name, item_prefix) and std.mem.endsWith(u8, e.name, item_suffix)) {
            xhtml_count += 1;
        }
        // K2 (id 2) must NOT appear; only K4 (id 4) does.
        if (std.mem.indexOf(u8, e.data, ">K2<") != null) has_k2 = true;
    }
    try std.testing.expectEqual(@as(usize, 1), xhtml_count);
    try std.testing.expect(!has_k2);

    const next = try decode(gpa, result.?.next_token);
    try std.testing.expectEqual(Kind.knowledge, next.kind);
    try std.testing.expectEqual(@as(u64, 4), next.id);
}

test "resolve: never crosses kinds" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithRecords(4, .{
        .{ .kind = .news, .title = "N1", .body = "" },
        .{ .kind = .knowledge, .title = "K2", .body = "" },
        .{ .kind = .news, .title = "N3", .body = "" },
        .{ .kind = .knowledge, .title = "K4", .body = "" },
    });
    defer {
        store.deinit();
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, "zig-cache/tmp/download-store.jsonl") catch {};
    }

    // news token: only N1, N3 returned; no K records.
    const result = try resolve(gpa, &store, .{ .kind = .news, .id = 0 }, null);
    try std.testing.expect(result != null);
    defer {
        gpa.free(result.?.epub);
        gpa.free(result.?.next_token);
    }

    var entries = try readZipEntries(gpa, result.?.epub);
    defer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        entries.deinit(gpa);
    }
    for (entries.items) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.data, "K2") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.data, "K4") == null);
    }
}

test "resolve: non-empty resolve records one generation for the resolved kind" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithRecords(3, .{
        .{ .kind = .news, .title = "N1", .body = "" },
        .{ .kind = .news, .title = "N3", .body = "" },
        .{ .kind = .knowledge, .title = "K2", .body = "" },
    });
    defer {
        store.deinit();
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, "zig-cache/tmp/download-store.jsonl") catch {};
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    const result = try resolve(gpa, &store, .{ .kind = .news, .id = 0 }, &m);
    try std.testing.expect(result != null);
    defer {
        gpa.free(result.?.epub);
        gpa.free(result.?.next_token);
    }

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"news\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"knowledge\"} 0") != null);
}

test "resolve: two kinds are recorded distinctly" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithRecords(5, .{
        .{ .kind = .news, .title = "N1", .body = "" },
        .{ .kind = .knowledge, .title = "K2", .body = "" },
        .{ .kind = .news, .title = "N3", .body = "" },
        .{ .kind = .knowledge, .title = "K4", .body = "" },
        .{ .kind = .news, .title = "N5", .body = "" },
    });
    defer {
        store.deinit();
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, "zig-cache/tmp/download-store.jsonl") catch {};
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    const r1 = try resolve(gpa, &store, .{ .kind = .news, .id = 0 }, &m);
    try std.testing.expect(r1 != null);
    defer {
        gpa.free(r1.?.epub);
        gpa.free(r1.?.next_token);
    }
    const r2 = try resolve(gpa, &store, .{ .kind = .knowledge, .id = 0 }, &m);
    try std.testing.expect(r2 != null);
    defer {
        gpa.free(r2.?.epub);
        gpa.free(r2.?.next_token);
    }

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"news\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"knowledge\"} 1") != null);
}

test "resolve: nothing-new resolve records nothing in the metrics" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithRecords(3, .{
        .{ .kind = .news, .title = "N1", .body = "" },
        .{ .kind = .knowledge, .title = "K2", .body = "" },
        .{ .kind = .news, .title = "N3", .body = "" },
    });
    defer {
        store.deinit();
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, "zig-cache/tmp/download-store.jsonl") catch {};
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    // Largest news id is 3; token {news,3} is empty → nothing-new.
    const result = try resolve(gpa, &store, .{ .kind = .news, .id = 3 }, &m);
    try std.testing.expect(result == null);

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"news\"} 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"knowledge\"} 0") != null);
}
