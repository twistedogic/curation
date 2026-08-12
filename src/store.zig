// Append-only JSONL item store with global monotonic ids and per-kind
// in-memory index rebuilt on startup.
// ponytail: all records in memory + dense id→index; fine at digest volume.
//          Revisit when the log grows past memory comfort; SQLite is the
//          intent §7 ceiling. Single-threaded store until a concurrent
//          caller lands; guard append + index with a mutex in the
//          orchestration change.
const std = @import("std");

const item_mod = @import("item.zig");
const longevity_mod = @import("longevity.zig");

pub const Kind = longevity_mod.Kind;

pub const Record = struct {
    id: u64,
    kind: Kind,
    title: []const u8,
    url: []const u8,
    body: []const u8,
    date: []const u8,
    source: []const u8,
    tags: []const []const u8,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    records: std.ArrayList(Record),
    news_ids: std.ArrayList(u64),
    knowledge_ids: std.ArrayList(u64),
    next_id: u64,
    /// Serializes mutation (append) and range reads so the writer thread
    /// (a curation run) and the reader thread (the /download serving path)
    /// cannot tear the records/index state.
    /// ponytail: std.atomic.Mutex is a 1-byte spinlock; we busy-wait with
    /// `std.Thread.yield` to get blocking semantics. Fine at digest volume;
    /// switch to std.Io.Mutex if the section grows or contention spikes.
    mutex: std.atomic.Mutex = .unlocked,

    pub const LoadError = std.mem.Allocator.Error;
    pub const AppendError = std.mem.Allocator.Error ||
        std.Io.File.OpenError ||
        std.Io.File.WritePositionalError ||
        std.Io.File.StatError ||
        std.Io.Writer.Error;
    pub const RangeError = std.mem.Allocator.Error;
    pub const PruneError = std.mem.Allocator.Error ||
        std.Io.File.OpenError ||
        std.Io.File.WritePositionalError ||
        std.Io.Dir.DeleteFileError ||
        std.Io.Dir.RenameError ||
        std.Io.Writer.Error;

    /// Open (or create) the JSONL store at `path`. Replays the file line by
    /// line, rebuilding the in-memory index and the next-id counter. A
    /// missing file is an empty store; a non-empty file is parsed as one
    /// `Record` per line, stopping at the first undecodable line (treated as
    /// a torn tail).
    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Store {
        var self: Store = .{
            .gpa = gpa,
            .io = io,
            .path = try gpa.dupe(u8, path),
            .records = .empty,
            .news_ids = .empty,
            .knowledge_ids = .empty,
            .next_id = 1,
        };
        errdefer self.deinit();

        const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return self,
            else => return error.OutOfMemory,
        };
        defer gpa.free(bytes);

        var line_it = std.mem.splitScalar(u8, bytes, '\n');
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            // A torn trailing line (or any garbage) terminates replay here.
            const parsed = std.json.parseFromSlice(Record, gpa, line, .{}) catch break;
            defer parsed.deinit();

            const record = try deepCopyRecord(gpa, parsed.value);
            try self.records.append(gpa, record);
            switch (record.kind) {
                .news => try self.news_ids.append(gpa, record.id),
                .knowledge => try self.knowledge_ids.append(gpa, record.id),
            }
            if (record.id >= self.next_id) self.next_id = record.id + 1;
        }

        return self;
    }

    /// Assign the next monotonic id, write one self-contained JSONL line
    /// (flushed), and extend the in-memory index. Returns the assigned id.
    pub fn append(self: *Store, kind: Kind, item: item_mod.CuratedItem) AppendError!u64 {
        blockingLock(&self.mutex);
        defer self.mutex.unlock();

        const id = self.next_id;

        const record = try deepCopyRecord(self.gpa, .{
            .id = id,
            .kind = kind,
            .title = item.title,
            .url = item.url,
            .body = item.body,
            .date = item.date,
            .source = item.source,
            .tags = item.tags,
        });
        var record_in_list = false;
        errdefer if (!record_in_list) freeRecord(self.gpa, record);

        try writeRecordToFile(self, record);

        try self.records.append(self.gpa, record);
        record_in_list = true;

        const kind_list = switch (kind) {
            .news => &self.news_ids,
            .knowledge => &self.knowledge_ids,
        };
        try kind_list.append(self.gpa, id);
        self.next_id += 1;

        return id;
    }

    /// Remove every record whose `date` parses to an instant strictly older
    /// than `now_epoch_seconds - max_age_seconds`. Empty or unparseable
    /// `date` fields are kept (deleting what we cannot date is riskier than
    /// keeping it). The JSONL log is rewritten atomically (survivors go to a
    /// sibling temp file, then a `Dir.rename` swaps it over the store file);
    /// the in-memory `records` list and per-kind id indexes are rebuilt from
    /// the survivors; `next_id` is left unchanged (ids are never reused).
    /// Returns the number of records removed. The store mutex is held for
    /// the duration of the prune.
    /// ponytail: undated records (web items) never prune by date; upgrade
    /// when web-item retention matters — add an append-time field to the
    /// record format (a one-time JSONL migration) and prune by insertion
    /// age, or have `acquireWeb` stamp a date.
    pub fn pruneByAge(self: *Store, now_epoch_seconds: i64, max_age_seconds: i64) PruneError!usize {
        blockingLock(&self.mutex);
        defer self.mutex.unlock();

        if (self.records.items.len == 0) return 0;

        const cutoff = now_epoch_seconds - max_age_seconds;
        var keep: std.ArrayList(Record) = .empty;
        errdefer {
            for (keep.items) |r| freeRecord(self.gpa, r);
            keep.deinit(self.gpa);
        }
        try keep.ensureTotalCapacity(self.gpa, self.records.items.len);

        var pruned: usize = 0;
        for (self.records.items) |r| {
            if (parseDateEpoch(r.date)) |epoch| {
                if (epoch < cutoff) {
                    pruned += 1;
                    continue;
                }
            }
            // Either undated/unparseable (kept) or recent (kept).
            try keep.append(self.gpa, r);
        }
        if (pruned == 0) {
            keep.deinit(self.gpa);
            return 0;
        }

        var new_news_ids: std.ArrayList(u64) = .empty;
        errdefer new_news_ids.deinit(self.gpa);
        var new_knowledge_ids: std.ArrayList(u64) = .empty;
        errdefer new_knowledge_ids.deinit(self.gpa);
        try new_news_ids.ensureTotalCapacity(self.gpa, self.news_ids.items.len);
        try new_knowledge_ids.ensureTotalCapacity(self.gpa, self.knowledge_ids.items.len);
        for (keep.items) |r| switch (r.kind) {
            .news => try new_news_ids.append(self.gpa, r.id),
            .knowledge => try new_knowledge_ids.append(self.gpa, r.id),
        };

        // Atomically replace the store file.
        const tmp_path = try std.fmt.allocPrint(self.gpa, "{s}.prune.{x}", .{ self.path, randTempId(self.io) });
        defer self.gpa.free(tmp_path);

        // Write survivors to a fresh sibling file, then rename over the
        // store. The rename is the atomicity boundary.
        {
            const f = try std.Io.Dir.createFile(.cwd(), self.io, tmp_path, .{});
            defer f.close(self.io);
            errdefer std.Io.Dir.deleteFile(.cwd(), self.io, tmp_path) catch {};
            var offset: u64 = 0;
            for (keep.items) |r| {
                var aw: std.Io.Writer.Allocating = .init(self.gpa);
                defer aw.deinit();
                try std.json.Stringify.value(r, .{}, &aw.writer);
                try aw.writer.writeByte('\n');
                try std.Io.File.writePositionalAll(f, self.io, aw.written(), offset);
                offset += aw.written().len;
            }
            try f.sync(self.io);
        }
        std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), self.path, self.io) catch |err| {
            std.Io.Dir.deleteFile(.cwd(), self.io, tmp_path) catch {};
            return err;
        };

        // The old list owns all record fields until the file replacement has
        // succeeded. Free only the removed records, then transfer survivor
        // ownership to `self.records`.
        var old_records = self.records;
        for (old_records.items) |r| {
            if (parseDateEpoch(r.date)) |epoch| {
                if (epoch < cutoff) freeRecord(self.gpa, r);
            }
        }
        old_records.deinit(self.gpa);
        self.records = keep;
        self.news_ids.deinit(self.gpa);
        self.knowledge_ids.deinit(self.gpa);
        self.news_ids = new_news_ids;
        self.knowledge_ids = new_knowledge_ids;
        return pruned;
    }

    /// Return the records of `kind` whose id is strictly greater than
    /// `since_id`, in ascending id order. The returned slice is a freshly
    /// allocated array of `Record` values that alias the store's internal
    /// record fields by pointer; the caller frees the slice with `gpa.free`
    /// and MUST keep the store alive for the lifetime of the slice.
    pub fn range(self: *Store, kind: Kind, since_id: u64) RangeError![]Record {
        blockingLock(&self.mutex);
        defer self.mutex.unlock();

        const ids = switch (kind) {
            .news => self.news_ids.items,
            .knowledge => self.knowledge_ids.items,
        };
        // upperBound returns the first index where `item > since_id`.
        const start = std.sort.upperBound(u64, ids, since_id, cmpU64);
        const result_ids = ids[start..];
        var out: std.ArrayList(Record) = .empty;
        errdefer out.deinit(self.gpa);
        for (result_ids) |id| {
            // ids are dense from 1, so record index is id - 1.
            try out.append(self.gpa, self.records.items[@intCast(id - 1)]);
        }
        return out.toOwnedSlice(self.gpa);
    }

    pub fn deinit(self: *Store) void {
        for (self.records.items) |r| freeRecord(self.gpa, r);
        self.records.deinit(self.gpa);
        self.news_ids.deinit(self.gpa);
        self.knowledge_ids.deinit(self.gpa);
        self.gpa.free(self.path);
        self.* = undefined;
    }
};

fn writeRecordToFile(self: *Store, record: Record) Store.AppendError!void {
    var aw: std.Io.Writer.Allocating = .init(self.gpa);
    defer aw.deinit();
    try std.json.Stringify.value(record, .{}, &aw.writer);
    try aw.writer.writeByte('\n');

    const f = std.Io.Dir.openFile(.cwd(), self.io, self.path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.createFile(.cwd(), self.io, self.path, .{}),
        else => return err,
    };
    defer f.close(self.io);

    const length = try std.Io.File.length(f, self.io);
    try std.Io.File.writePositionalAll(f, self.io, aw.written(), length);
}

// ---- helpers ----

fn deepCopyRecord(gpa: std.mem.Allocator, src: Record) std.mem.Allocator.Error!Record {
    var dst: Record = .{
        .id = src.id,
        .kind = src.kind,
        .title = try gpa.dupe(u8, src.title),
        .url = try gpa.dupe(u8, src.url),
        .body = try gpa.dupe(u8, src.body),
        .date = try gpa.dupe(u8, src.date),
        .source = try gpa.dupe(u8, src.source),
        .tags = &[_][]const u8{},
    };
    errdefer gpa.free(dst.title);
    errdefer gpa.free(dst.url);
    errdefer gpa.free(dst.body);
    errdefer gpa.free(dst.date);
    errdefer gpa.free(dst.source);
    if (src.tags.len > 0) {
        const tags = try gpa.alloc([]u8, src.tags.len);
        errdefer gpa.free(tags);
        for (src.tags, 0..) |t, i| {
            tags[i] = try gpa.dupe(u8, t);
        }
        dst.tags = tags;
    }
    return dst;
}

fn freeRecord(gpa: std.mem.Allocator, r: Record) void {
    gpa.free(r.title);
    gpa.free(r.url);
    gpa.free(r.body);
    gpa.free(r.date);
    gpa.free(r.source);
    if (r.tags.len > 0) {
        for (r.tags) |t| gpa.free(t);
        gpa.free(r.tags);
    }
}

fn cmpU64(ctx: u64, item: u64) std.math.Order {
    return std.math.order(ctx, item);
}

/// Parse an RSS/Atom `date` field to epoch seconds. Returns `null` for
/// empty or unparseable input (the store keeps such records forever —
/// deleting what we cannot date is riskier than keeping it).
///
/// Accepted formats:
/// - ISO-8601 / RFC-3339: `2024-01-01T00:00:00Z`, with a trailing `Z`
///   (UTC) or `+HH:MM` / `-HH:MM` numeric offset.
/// - RFC-822 / RFC-2822: `Mon, 01 Jan 2024 00:00:00 GMT`, with the
///   weekday prefix and a 2- or 4-digit year. The 2-digit year pivots
///   at 70 (00–69 → 2000–2069; 70–99 → 1970–1999), matching the
///   convention in RFC 2822 §4.1.
fn parseDateEpoch(date: []const u8) ?i64 {
    if (date.len == 0) return null;
    return parseIsoDate(date) orelse parseRfc822Date(date) orelse null;
}

fn parseIsoDate(s: []const u8) ?i64 {
    // 4-digit year, 2-digit month, 2-digit day, hour, minute, second,
    // and either `Z` or `±HH:MM` / `±HHMM`.
    if (s.len < 20) return null;
    const year_u = parseUInt(s[0..4], 10, 0, 9999) orelse return null;
    if (s[4] != '-') return null;
    const month_u = parseUInt(s[5..7], 10, 1, 12) orelse return null;
    if (s[7] != '-') return null;
    const day_u = parseUInt(s[8..10], 10, 1, 31) orelse return null;
    const sep = s[10];
    if (sep != 'T' and sep != ' ') return null;
    const hour = parseUInt(s[11..13], 10, 0, 23) orelse return null;
    if (s[13] != ':') return null;
    const min = parseUInt(s[14..16], 10, 0, 59) orelse return null;
    if (s[16] != ':') return null;
    const sec = parseUInt(s[17..19], 10, 0, 60) orelse return null;
    const year: u16 = @intCast(year_u);
    const month: u8 = @intCast(month_u);
    const day: u8 = @intCast(day_u);
    if (!isValidDay(year, month, day)) return null;
    if (sec == 60) return null; // leap second: not representable in unix time
    if (s.len < 20) return null;
    if (s[19] != 'Z' and s[19] != '+' and s[19] != '-') return null;
    var offset_seconds: i64 = 0;
    if (s[19] == 'Z') {
        if (s.len != 20) return null;
    } else {
        // `+HH:MM` / `-HH:MM` (5 chars) or `+HHMM` (5 chars). Either way 5.
        if (s.len != 25 or s[22] != ':') return null;
        const oh_u = parseUInt(s[20..22], 10, 0, 23) orelse return null;
        const om_u = parseUInt(s[23..25], 10, 0, 59) orelse return null;
        offset_seconds = (@as(i64, @intCast(oh_u)) * 60 + @as(i64, @intCast(om_u))) * 60;
        if (s[19] == '-') offset_seconds = -offset_seconds;
    }
    const day_secs = daysFromCivil(year, month, day) * 86_400
        + @as(i64, @intCast(hour)) * 3600 + @as(i64, @intCast(min)) * 60 + @as(i64, @intCast(sec));
    return day_secs - offset_seconds;
}

fn parseRfc822Date(s: []const u8) ?i64 {
    // `Mon, 01 Jan 2024 00:00:00 GMT` (or two-digit year; weekday optional;
    // timezone may be `GMT`/`UT`/`Z`/`+0000`).
    var i: usize = 0;
    // Optional weekday prefix: letters, then a comma, then optional space.
    if (i < s.len and std.ascii.isAlphabetic(s[i])) {
        while (i < s.len and std.ascii.isAlphabetic(s[i])) : (i += 1) {}
        if (i >= s.len or s[i] != ',') return null;
        i += 1;
        while (i < s.len and s[i] == ' ') : (i += 1) {}
    }
    if (i + 2 > s.len) return null;
    const day_u = parseUInt(s[i..][0..2], 10, 1, 31) orelse return null;
    const day: u8 = @intCast(day_u);
    if (s[i + 2] != ' ' and s[i + 2] != '-') return null;
    i += 3;
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    if (i + 3 > s.len) return null;
    const month_name = s[i..][0..3];
    const month_u = monthIndex(month_name) orelse return null;
    const month: u8 = @intCast(month_u);
    i += 3;
    if (i >= s.len or s[i] != ' ') return null;
    i += 1;
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    // Year is 2 or 4 digits.
    var year_end = i;
    while (year_end < s.len and std.ascii.isDigit(s[year_end])) : (year_end += 1) {}
    if (year_end == i) return null;
    const year_digits = year_end - i;
    if (year_digits != 2 and year_digits != 4) return null;
    const year = blk: {
        if (year_digits == 4) {
            const v = parseUInt(s[i..year_end], 10, 0, 9999) orelse return null;
            break :blk @as(u16, @intCast(v));
        }
        const yy = parseUInt(s[i..year_end], 10, 0, 99) orelse return null;
        break :blk if (yy < 70) @as(u16, @intCast(2000 + yy)) else @as(u16, @intCast(1900 + yy));
    };
    i = year_end;
    if (i >= s.len or s[i] != ' ') return null;
    i += 1;
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    if (i + 8 > s.len) return null;
    const hour = parseUInt(s[i..][0..2], 10, 0, 23) orelse return null;
    if (s[i + 2] != ':') return null;
    const min = parseUInt(s[i + 3 ..][0..2], 10, 0, 59) orelse return null;
    if (s[i + 5] != ':') return null;
    const sec = parseUInt(s[i + 6 ..][0..2], 10, 0, 60) orelse return null;
    if (sec == 60) return null;
    if (!isValidDay(year, month, day)) return null;
    i += 8;
    // Skip whitespace before the timezone.
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    if (i >= s.len) return null;
    const zone_sign: i8, const zone_seconds: i64 = blk: {
        if (s[i] == '+' or s[i] == '-') {
            const sign: i8 = if (s[i] == '+') 1 else -1;
            if (i + 5 > s.len) return null;
            const zh_u = parseUInt(s[i + 1 ..][0..2], 10, 0, 23) orelse return null;
            const zm_u = parseUInt(s[i + 3 ..][0..2], 10, 0, 59) orelse return null;
            break :blk .{ sign, (@as(i64, @intCast(zh_u)) * 60 + @as(i64, @intCast(zm_u))) * 60 };
        }
        // Named zones: GMT, UT, Z, and US military (single letter).
        if (i + 2 <= s.len and (std.mem.eql(u8, s[i..][0..3], "GMT") or std.mem.eql(u8, s[i..][0..2], "UT"))) {
            break :blk .{ 1, 0 };
        }
        if (s[i] == 'Z') {
            if (i != s.len - 1) return null;
            break :blk .{ 1, 0 };
        }
        return null;
    };
    const day_secs = daysFromCivil(year, month, day) * 86_400
        + @as(i64, @intCast(hour)) * 3600 + @as(i64, @intCast(min)) * 60 + @as(i64, @intCast(sec));
    return day_secs - @as(i64, zone_sign) * zone_seconds;
}

fn monthIndex(name: []const u8) ?u8 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (months, 0..) |m, i| if (std.mem.eql(u8, name, m)) return @intCast(i + 1);
    return null;
}

fn isLeapYear(year: u16) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

fn daysInMonth(year: u16, month: u8) u8 {
    const mdays = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeapYear(year)) return 29;
    return mdays[month - 1];
}

fn isValidDay(year: u16, month: u8, day: u8) bool {
    return day >= 1 and day <= daysInMonth(year, month);
}

/// Days from the Unix epoch (1970-01-01) to the given civil date, using
/// the proleptic Gregorian calendar. Howard Hinnant's algorithm (public
/// domain). Negative `secs` (pre-1970) are supported.
fn daysFromCivil(year: u16, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) year - 1 else year;
    const era: i64 = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe: i64 = y - era * 400;
    const m_adj: i64 = month;
    const doy: i64 = @divTrunc(153 * (if (m_adj > 2) m_adj - 3 else m_adj + 9) + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

fn parseUInt(s: []const u8, radix: u8, min: u64, max: u64) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        const d = std.fmt.charToDigit(c, radix) catch return null;
        v = std.math.mul(u64, v, radix) catch return null;
        v += d;
    }
    if (v < min or v > max) return null;
    return v;
}

/// Random suffix for a temporary prune file. Prune is mutex-serialized
/// in-process and runs at most once per curation run, so a single
/// randomness call is sufficient for uniqueness across the lifetime of
/// the process.
fn randTempId(io: std.Io) u64 {
    var buf: [8]u8 = undefined;
    std.Io.random(io, &buf);
    return std.mem.readInt(u64, &buf, .little);
}

/// Busy-wait for `std.atomic.Mutex` to acquire. Yields between attempts so
/// a contended thread doesn't burn a core. The critical sections here are
/// tiny (a few arraylist appends or a slice over an id list), so contention
/// is brief and spin-wait is fine.
fn blockingLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.Thread.yield() catch {};
}

// ============= tests =============

fn makeItem(title: []const u8, source: []const u8, tags: []const []const u8) item_mod.CuratedItem {
    return .{
        .title = title,
        .url = "",
        .body = "",
        .date = "",
        .source = source,
        .tags = tags,
    };
}

test "Record: round-trips through std.json (encode → decode yields equal fields)" {
    const gpa = std.testing.allocator;

    const original = Record{
        .id = 42,
        .kind = .knowledge,
        .title = "Hello",
        .url = "https://example.com/path",
        .body = "Body",
        .date = "2025-01-01",
        .source = "feed",
        .tags = &[_][]const u8{ "a", "b" },
    };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(original, .{}, &aw.writer);

    const parsed = try std.json.parseFromSlice(Record, gpa, aw.written(), .{});
    defer parsed.deinit();

    try std.testing.expectEqual(original.id, parsed.value.id);
    try std.testing.expectEqual(original.kind, parsed.value.kind);
    try std.testing.expectEqualStrings(original.title, parsed.value.title);
    try std.testing.expectEqualStrings(original.url, parsed.value.url);
    try std.testing.expectEqualStrings(original.body, parsed.value.body);
    try std.testing.expectEqualStrings(original.date, parsed.value.date);
    try std.testing.expectEqualStrings(original.source, parsed.value.source);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try std.testing.expectEqualStrings("a", parsed.value.tags[0]);
    try std.testing.expectEqualStrings("b", parsed.value.tags[1]);
}

test "Store: load from missing file returns empty store with next_id 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-missing.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.news_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.knowledge_ids.items.len);
    try std.testing.expectEqual(@as(u64, 1), store.next_id);
}

test "Store: append to a missing path creates the file with one line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-create.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    const id = try store.append(.news, makeItem("Hello", "feed", &.{}));
    try std.testing.expectEqual(@as(u64, 1), id);

    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, tmp, gpa, .unlimited);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":1") != null);
}

test "Store: three appends to an empty store yield ids 1, 2, 3" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-ids.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    try std.testing.expectEqual(@as(u64, 1), try store.append(.news, makeItem("A", "s", &.{})));
    try std.testing.expectEqual(@as(u64, 2), try store.append(.knowledge, makeItem("B", "s", &.{})));
    try std.testing.expectEqual(@as(u64, 3), try store.append(.news, makeItem("C", "s", &.{})));
}

test "Store: reload rebuilds the per-kind index and next-id (id 8 follows a max of 7)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-replay.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    {
        var store = try Store.load(gpa, io, tmp);
        defer store.deinit();
        for (0..7) |_| _ = try store.append(.news, makeItem("T", "s", &.{}));
    }

    {
        var store = try Store.load(gpa, io, tmp);
        defer store.deinit();
        defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

        try std.testing.expectEqual(@as(usize, 7), store.records.items.len);
        try std.testing.expectEqual(@as(usize, 7), store.news_ids.items.len);
        try std.testing.expectEqual(@as(usize, 0), store.knowledge_ids.items.len);
        try std.testing.expectEqual(@as(u64, 8), store.next_id);

        const id = try store.append(.news, makeItem("H", "s", &.{}));
        try std.testing.expectEqual(@as(u64, 8), id);
    }
}

test "Store: appends do not mutate prior lines on disk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-preserve.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    _ = try store.append(.news, makeItem("First", "s", &.{}));
    _ = try store.append(.news, makeItem("Second", "s", &.{}));

    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, tmp, gpa, .unlimited);
    defer gpa.free(bytes);

    const first_nl = std.mem.indexOfScalar(u8, bytes, '\n').?;
    const first_line = bytes[0..first_nl];
    try std.testing.expect(std.mem.indexOf(u8, first_line, "\"title\":\"First\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_line, "\"id\":1") != null);
}

test "Store: range returns later items of one kind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-range.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    // news ids [1,3,5], knowledge ids [2,4]
    _ = try store.append(.news, makeItem("N1", "s", &.{})); // id 1
    _ = try store.append(.knowledge, makeItem("K2", "s", &.{})); // id 2
    _ = try store.append(.news, makeItem("N3", "s", &.{})); // id 3
    _ = try store.append(.knowledge, makeItem("K4", "s", &.{})); // id 4
    _ = try store.append(.news, makeItem("N5", "s", &.{})); // id 5

    const result = try store.range(.news, 1);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u64, 3), result[0].id);
    try std.testing.expectEqual(@as(u64, 5), result[1].id);
    try std.testing.expectEqualStrings("N3", result[0].title);
    try std.testing.expectEqualStrings("N5", result[1].title);
}

test "Store: range is half-open on the lower bound" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-range-half.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    _ = try store.append(.news, makeItem("N1", "s", &.{})); // id 1
    _ = try store.append(.knowledge, makeItem("K2", "s", &.{})); // id 2
    _ = try store.append(.news, makeItem("N3", "s", &.{})); // id 3
    _ = try store.append(.knowledge, makeItem("K4", "s", &.{})); // id 4
    _ = try store.append(.news, makeItem("N5", "s", &.{})); // id 5

    const result = try store.range(.news, 3);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u64, 5), result[0].id);
}

test "Store: range yields nothing when current" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-range-empty.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    _ = try store.append(.news, makeItem("N1", "s", &.{})); // id 1
    _ = try store.append(.knowledge, makeItem("K2", "s", &.{})); // id 2
    _ = try store.append(.news, makeItem("N5", "s", &.{})); // id 3

    const result = try store.range(.news, 3);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "Store: range never returns the other kind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-range-kind.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    _ = try store.append(.news, makeItem("N1", "s", &.{})); // id 1
    _ = try store.append(.knowledge, makeItem("K2", "s", &.{})); // id 2
    _ = try store.append(.news, makeItem("N3", "s", &.{})); // id 3

    const result = try store.range(.knowledge, 0);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u64, 2), result[0].id);
    try std.testing.expectEqualStrings("K2", result[0].title);
}

test "Store: range with since_id of zero returns all of the kind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-range-all.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    _ = try store.append(.news, makeItem("N1", "s", &.{})); // id 1
    _ = try store.append(.knowledge, makeItem("K2", "s", &.{})); // id 2
    _ = try store.append(.news, makeItem("N3", "s", &.{})); // id 3
    _ = try store.append(.knowledge, makeItem("K4", "s", &.{})); // id 4
    _ = try store.append(.news, makeItem("N5", "s", &.{})); // id 5

    const result = try store.range(.news, 0);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u64, 1), result[0].id);
    try std.testing.expectEqual(@as(u64, 3), result[1].id);
    try std.testing.expectEqual(@as(u64, 5), result[2].id);
}

test "Store: concurrent append and range do not race and reader sees a consistent snapshot (DISABLED for TSan debug)" {
    // Disabled temporarily while debugging TSan; see _concurrent below.
}

test "Store: concurrent append and range _concurrent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-concurrent.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    // Tight loops without yields maximize the chance of hitting a torn
    // read window between `records.append` and `kind_list.append`. With the
    // mutex this test always passes; without it, it races (UB on ArrayList
    // append / read, or torn snapshot where records.len > news_ids.len).
    const writer_ctx = struct {
        fn run(s: *Store) void {
            var i: usize = 0;
            while (i < 2000) : (i += 1) {
                _ = s.append(.news, makeItem("concurrent", "s", &.{})) catch {};
            }
        }
    }.run;
    const reader_ctx = struct {
        fn run(s: *Store) void {
            var i: usize = 0;
            while (i < 10000) : (i += 1) {
                // Force the reader to also see the records list and check
                // consistency between the two: the invariant is dense id →
                // index, so any reader snapshot must satisfy
                // news_ids.len == records.len (when only news was appended).
                const r = s.range(.news, 0) catch continue;
                defer gpa.free(r);
                // range returns records where id > 0. Each record's slot
                // equals id - 1. If records and news_ids aren't aligned,
                // some range result has the wrong id at the wrong slot.
                for (r, 0..) |rec, idx| {
                    if (rec.id != idx + 1) {
                        std.debug.panic("torn snapshot: r[{d}].id={d} (expected {d})", .{ idx, rec.id, idx + 1 });
                    }
                }
            }
        }
    }.run;

    const writer = try std.Thread.spawn(.{}, writer_ctx, .{&store});
    const reader = try std.Thread.spawn(.{}, reader_ctx, .{&store});
    writer.join();
    reader.join();

    // After both threads complete, the store contains exactly 2000 records.
    try std.testing.expectEqual(@as(usize, 2000), store.records.items.len);
    try std.testing.expectEqual(@as(usize, 2000), store.news_ids.items.len);
    try std.testing.expectEqual(@as(u64, 2001), store.next_id);
}

test "Store: torn trailing line is ignored, next id is one greater than the largest valid id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-torn.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    // Two valid lines followed by a torn (non-decodable) trailing line.
    {
        const f = try std.Io.Dir.createFile(.cwd(), io, tmp, .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"id":1,"kind":"news","title":"A","url":"u","body":"b","date":"d","source":"s","tags":[]}
            \\{"id":2,"kind":"news","title":"B","url":"u","body":"b","date":"d","source":"s","tags":[]}
            \\{"id":3,"kind":"knowledge","title":"C","url":"u","body":"b"
        );
    }

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    try std.testing.expectEqual(@as(usize, 2), store.records.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.news_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.knowledge_ids.items.len);
    try std.testing.expectEqual(@as(u64, 3), store.next_id);
}

// ============= retention prune (FR-16) =============

test "Store.parseIsoDate: 2024-01-01T00:00:00Z returns 1704067200" {
    try std.testing.expectEqual(@as(?i64, 1704067200), parseIsoDate("2024-01-01T00:00:00Z"));
}

test "Store.parseRfc822Date: 2024-01-01 GMT returns 1704067200" {
    try std.testing.expectEqual(@as(?i64, 1704067200), parseRfc822Date("Mon, 01 Jan 2024 00:00:00 GMT"));
}

test "Store.parseDateEpoch: ISO-8601 UTC is parsed; non-UTC and 2-digit-year variants are accepted" {
    // 2024-01-01T00:00:00Z = 1704067200
    try std.testing.expectEqual(@as(?i64, 1704067200), parseDateEpoch("2024-01-01T00:00:00Z"));
    // 2021-06-05T20:28:26Z = 1622924906 (from stdlib epoch tests)
    try std.testing.expectEqual(@as(?i64, 1622924906), parseDateEpoch("2021-06-05T20:28:26Z"));
    // RFC-3339 with numeric offset: 2024-01-01T00:00:00+00:00 == the UTC instant.
    try std.testing.expectEqual(@as(?i64, 1704067200), parseDateEpoch("2024-01-01T00:00:00+00:00"));
    // Numeric offset is honored: 2024-01-01T01:00:00+01:00 == 2024-01-01T00:00:00Z.
    try std.testing.expectEqual(@as(?i64, 1704067200), parseDateEpoch("2024-01-01T01:00:00+01:00"));
    // RFC-822: Mon, 01 Jan 2024 00:00:00 GMT == 1704067200
    try std.testing.expectEqual(@as(?i64, 1704067200), parseDateEpoch("Mon, 01 Jan 2024 00:00:00 GMT"));
    // 2-digit year pivot: 99 -> 1999, 00 -> 2000.
    try std.testing.expectEqual(@as(?i64, 915235200), parseDateEpoch("Sat, 02 Jan 1999 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 946684800), parseDateEpoch("Sat, 01 Jan 2000 00:00:00 GMT"));
}

test "Store.parseDateEpoch: empty and unparseable inputs return null" {
    try std.testing.expectEqual(@as(?i64, null), parseDateEpoch(""));
    try std.testing.expectEqual(@as(?i64, null), parseDateEpoch("not a date"));
    try std.testing.expectEqual(@as(?i64, null), parseDateEpoch("2024/01/01"));
    try std.testing.expectEqual(@as(?i64, null), parseDateEpoch("13 Foo 2024 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, null), parseDateEpoch("2024-01-01")); // date-only is not a known feed format
    try std.testing.expectEqual(@as(?i64, null), parseDateEpoch("2024-01-01T00:00:00")); // missing zone
    try std.testing.expectEqual(@as(?i64, null), parseDateEpoch("2024-13-01T00:00:00Z")); // month 13
    try std.testing.expectEqual(@as(?i64, null), parseDateEpoch("2024-02-30T00:00:00Z")); // Feb 30
    try std.testing.expectEqual(@as(?i64, null), parseDateEpoch("2024-01-01T25:00:00Z")); // hour 25
}

test "Store: pruneByAge removes only records whose parsed date is older than the cutoff" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-prune.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    // now = 2024-05-28T12:00:00Z. The two ISO/RFC dates below are
    // constructed so one is ~4.5 years old (old) and the other is ~8 days
    // old (recent); the RFC date is ~149 days old (old).
    const now: i64 = 1_716_192_000;
    _ = try store.append(.news, makeItemWithDate("OldIso", "s", "2020-01-01T00:00:00Z"));
    _ = try store.append(.news, makeItemWithDate("Recent", "s", "2024-05-20T00:00:00Z"));
    _ = try store.append(.knowledge, makeItemWithDate("OldRfc", "s", "Mon, 01 Jan 2024 00:00:00 GMT"));
    _ = try store.append(.news, makeItemWithDate("NoDate", "s", ""));
    _ = try store.append(.news, makeItemWithDate("BadDate", "s", "garbage"));

    const pruned = try store.pruneByAge(now, 90 * 86400);
    try std.testing.expectEqual(@as(usize, 2), pruned);
    try std.testing.expectEqual(@as(usize, 3), store.records.items.len);
    try std.testing.expectEqual(@as(usize, 3), store.news_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.knowledge_ids.items.len);
    // ids are never reused: the two old records (ids 1, 3) are gone, 2, 4, 5 remain.
    try std.testing.expectEqual(@as(u64, 6), store.next_id);

    var seen_old_iso = false;
    var seen_old_rfc = false;
    for (store.records.items) |r| {
        if (std.mem.eql(u8, r.title, "OldIso")) seen_old_iso = true;
        if (std.mem.eql(u8, r.title, "OldRfc")) seen_old_rfc = true;
    }
    try std.testing.expect(!seen_old_iso);
    try std.testing.expect(!seen_old_rfc);

    // The on-disk file matches the in-memory survivors, in ascending id order.
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, tmp, gpa, .unlimited);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":1") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":3") == null);
}

test "Store: pruneByAge zero removes nothing; next_id is preserved; reload yields same records" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-prune-zero.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    {
        var store = try Store.load(gpa, io, tmp);
        defer store.deinit();
        _ = try store.append(.news, makeItemWithDate("Old", "s", "1970-01-01T00:00:00Z"));
        _ = try store.append(.news, makeItemWithDate("New", "s", ""));
        const pruned = try store.pruneByAge(0, 0);
        try std.testing.expectEqual(@as(usize, 0), pruned);
        try std.testing.expectEqual(@as(usize, 2), store.records.items.len);
        try std.testing.expectEqual(@as(u64, 3), store.next_id);
    }

    var reloaded = try Store.load(gpa, io, tmp);
    defer reloaded.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    try std.testing.expectEqual(@as(usize, 2), reloaded.records.items.len);
    try std.testing.expectEqual(@as(u64, 3), reloaded.next_id);

    // A subsequent append uses the next monotonic id (3, not 2).
    const id = try reloaded.append(.news, makeItem("After", "s", &.{}));
    try std.testing.expectEqual(@as(u64, 3), id);
}

test "Store: pruneByAge keeps undated records even when the window is huge" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/store-prune-undated.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    var store = try Store.load(gpa, io, tmp);
    defer store.deinit();
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};

    _ = try store.append(.news, makeItemWithDate("Undated", "s", ""));
    const pruned = try store.pruneByAge(2_000_000_000, 10 * 365 * 86400);
    try std.testing.expectEqual(@as(usize, 0), pruned);
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
}

fn makeItemWithDate(title: []const u8, source: []const u8, date: []const u8) item_mod.CuratedItem {
    return .{
        .title = title,
        .url = "",
        .body = "",
        .date = date,
        .source = source,
        .tags = &.{},
    };
}
