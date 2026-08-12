// Longevity evaluator: classifies curated items into short_term/long_term
// via pi subprocess, with SHA-256-keyed cache and failure-tolerant fallback.
// ponytail: one subprocess per uncached item, no template engine, single-file
// JSON cache; upgrade if throughput/repeat-counts grow past digest volumes.
const std = @import("std");

const log_mod = @import("log.zig");
const metrics_mod = @import("metrics.zig");

/// Stream kind. short_term → news, long_term → knowledge, unknown →
/// configured default kind (default `news`).
pub const Kind = enum { news, knowledge };

/// Raw label emitted (or failed to be parsed from) pi. `unknown` is a
/// failure result, not a third stream.
pub const Label = enum { short_term, long_term, unknown };

/// Default classification prompt (mirrors intent §9 #13; operators may
/// override via `PiConfig.prompt`).
pub const default_prompt: []const u8 =
    \\You are a content-lifespan classifier. Decide whether the article's useful
    \\life is SHORT_TERM (news, events, releases, commentary, anything stale
    \\within ~3 months) or LONG_TERM (durable knowledge: tutorials, references,
    \\explanations, fundamentals that stay useful for years). Reply with exactly
    \\one word: SHORT_TERM or LONG_TERM.
    \\Title: {title}
    \\Body: {body}
;

/// Configuration for the longevity evaluator. Loaded from the nested `pi`
/// object in config.json. All fields have safe defaults — a missing or empty
/// `pi` block leaves the evaluator at defaults.
pub const PiConfig = struct {
    /// Path to the `pi` binary. Default `"pi"` (PATH lookup).
    path: []const u8 = "pi",
    /// Optional `--model` pin. When null, pi uses its own default.
    model: ?[]const u8 = null,
    /// Classification prompt template (must contain `{title}` and `{body}`).
    prompt: []const u8 = default_prompt,
    /// Failure-fallback kind. Defaults to `news` per intent §9 #13
    /// (misfiling as disposable news is safer than polluting knowledge).
    default_kind: Kind = .news,
    /// Per-invocation wall-clock bound, in seconds. `productionInvoker`
    /// kills the child and surfaces an error when this elapses, so a
    /// wedged classification never stalls the run. Default `30`;
    /// `null` disables the bound for operators who want none.
    timeout_seconds: ?u32 = 30,
};

/// Map a label to a stream kind. `unknown` falls back to `default_kind`.
pub fn labelToKind(label: Label, default_kind: Kind) Kind {
    return switch (label) {
        .short_term => .news,
        .long_term => .knowledge,
        .unknown => default_kind,
    };
}

/// Strict single-token parser for pi stdout. Accepts `short_term` /
/// `long_term` case-insensitive. Whitespace is allowed between or around
/// tokens; any other character (quotes, braces, hyphens, etc.) makes the
/// result `unknown`. The first valid token in a whitespace-separated stream
/// wins (so `short_term extra stuff` → `short_term`).
pub fn parseLabel(stdout: []const u8) Label {
    var i: usize = 0;
    while (i < stdout.len) {
        // Skip whitespace between tokens.
        while (i < stdout.len and std.ascii.isWhitespace(stdout[i])) : (i += 1) {}
        if (i >= stdout.len) break;
        // Scan a token (alphanumeric + underscore). Any other character
        // (quote, brace, hyphen, etc.) means the output isn't a clean
        // token-stream — reject as `unknown`.
        var j = i;
        while (j < stdout.len and (std.ascii.isAlphanumeric(stdout[j]) or stdout[j] == '_')) : (j += 1) {}
        // The chunk from `i` to `j` must be either pure tokens or pure
        // whitespace. We just scanned a token; if there's anything else
        // right after (non-whitespace), reject.
        if (j < stdout.len and !std.ascii.isWhitespace(stdout[j])) return .unknown;
        const token = stdout[i..j];
        if (std.ascii.eqlIgnoreCase(token, "short_term")) return .short_term;
        if (std.ascii.eqlIgnoreCase(token, "long_term")) return .long_term;
        i = j;
    }
    return .unknown;
}

/// Hex-encoded SHA-256 of `title ++ body`. Caller owns the returned slice.
pub fn sha256Hex(gpa: std.mem.Allocator, title: []const u8, body: []const u8) std.mem.Allocator.Error![]u8 {
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(title);
    hasher.update(body);
    hasher.final(&hash);
    const encoded = std.fmt.bytesToHex(&hash, .lower);
    return gpa.dupe(u8, &encoded);
}

/// Render the prompt by substituting `{title}` and `{body}`. No template
/// engine — literal placeholder substitution. We replace `{title}` first so
/// a `{title}` literal inside the body value isn't accidentally substituted
/// when we replace `{body}` second.
pub fn renderPrompt(gpa: std.mem.Allocator, template: []const u8, title: []const u8, body: []const u8) std.mem.Allocator.Error![]u8 {
    const after_title = try std.mem.replaceOwned(u8, gpa, template, "{title}", title);
    errdefer gpa.free(after_title);
    const result = try std.mem.replaceOwned(u8, gpa, after_title, "{body}", body);
    gpa.free(after_title);
    return result;
}

/// Subprocess-invoker seam: takes a caller-supplied context, the eval config,
/// and a rendered prompt; returns pi's stdout bytes. Production wires
/// `productionInvoker`; tests pass a stub with a state pointer.
pub const Invoker = struct {
    ctx: *anyopaque,
    invoke: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, cfg: PiConfig, rendered_prompt: []const u8) anyerror![]u8,

    pub fn call(self: Invoker, gpa: std.mem.Allocator, io: std.Io, cfg: PiConfig, prompt: []const u8) anyerror![]u8 {
        return self.invoke(self.ctx, gpa, io, cfg, prompt);
    }
};

/// Persisted SHA-256(title+body)-keyed cache of successful classifications.
/// Loaded at construction; rewritten via `save` after a new successful
/// evaluation. Failed/`unknown` classifications are NEVER cached (so a
/// transient pi outage retries on the next run).
pub const EvalCache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    map: std.StringHashMapUnmanaged(Kind),

    /// Load a cache from `path`. Missing file → empty cache.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) std.mem.Allocator.Error!EvalCache {
        var self: EvalCache = .{
            .gpa = gpa,
            .io = io,
            .path = try gpa.dupe(u8, path),
            .map = .empty,
        };
        errdefer self.deinit();

        const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return self,
            else => return error.OutOfMemory,
        };
        defer gpa.free(bytes);

        var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.OutOfMemory;
        defer parsed.deinit();

        const obj = parsed.value.object;
        var it = obj.iterator();
        while (it.next()) |kv| {
            const kind_str = switch (kv.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            const kind = std.meta.stringToEnum(Kind, kind_str) orelse continue;
            try self.put(kv.key_ptr.*, kind);
        }
        return self;
    }

    pub fn deinit(self: *EvalCache) void {
        // ponytail: StringHashMapUnmanaged does NOT free owned keys, so free
        // them here before releasing the buckets. Linear in entry count, fine
        // at digest volumes.
        var it = self.map.iterator();
        while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.map.deinit(self.gpa);
        self.gpa.free(self.path);
        self.* = undefined;
    }

    /// Look up a cached kind by hex SHA-256 key. Returns null on a miss.
    pub fn lookup(self: *const EvalCache, key: []const u8) ?Kind {
        return self.map.get(key);
    }

    /// Insert a kind. The key is deep-copied into the cache so the caller
    /// may free its copy immediately after.
    pub fn put(self: *EvalCache, key: []const u8, kind: Kind) std.mem.Allocator.Error!void {
        // ponytail: StringHashMapUnmanaged stores the slice header (ptr+len),
        // not the bytes. Dupe so the cache owns an independent copy and is
        // safe across caller frees.
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        const result = try self.map.getOrPut(self.gpa, owned);
        if (result.found_existing) self.gpa.free(owned);
        result.value_ptr.* = kind;
    }

    /// Persist the cache to `self.path` as one JSON object.
    pub fn save(self: *EvalCache) (std.Io.Writer.Error || std.Io.File.Writer.Error || std.Io.File.OpenError)!void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{");
        var first = true;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (!first) try w.writeAll(",");
            try w.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, @tagName(entry.value_ptr.*) });
            first = false;
        }
        try w.writeAll("}");

        const f = try std.Io.Dir.createFile(.cwd(), self.io, self.path, .{});
        defer f.close(self.io);
        try f.writeStreamingAll(self.io, aw.written());
    }
};

/// End-to-end classification: cache lookup → render → invoke → parse →
/// cache write (on success) → fallback to `cfg.default_kind` on failure.
/// Never aborts; never returns an error. When `metrics` is non-null, each
/// ACTUAL pi invocation (cache miss only) records one evaluation, the
/// invocation's latency, and (on error or unknown label) one failure;
/// a cache hit records nothing. A null recorder is a no-op.
pub fn classify(
    gpa: std.mem.Allocator,
    io: std.Io,
    title: []const u8,
    body: []const u8,
    cfg: PiConfig,
    invoker: Invoker,
    cache: *EvalCache,
    log_writer: *std.Io.Writer,
    metrics: ?*metrics_mod.Metrics,
) Kind {
    const key = sha256Hex(gpa, title, body) catch |err| {
        logFailure(log_writer, "longevity.cache_key_failed", err);
        return cfg.default_kind;
    };
    defer gpa.free(key);

    if (cache.lookup(key)) |kind| return kind;

    const rendered = renderPrompt(gpa, cfg.prompt, title, body) catch |err| {
        logFailure(log_writer, "longevity.render_failed", err);
        return cfg.default_kind;
    };
    defer gpa.free(rendered);

    // Time the actual pi invocation for the metrics histogram.
    const start_ns = std.Io.Clock.now(.awake, io).toNanoseconds();
    const stdout = invoker.call(gpa, io, cfg, rendered) catch |err| {
        recordEval(metrics, gpa, log_writer, start_ns, io, true);
        logFailure(log_writer, "longevity.invoke_failed", err);
        return cfg.default_kind;
    };
    defer gpa.free(stdout);

    const label = parseLabel(stdout);
    const kind = labelToKind(label, cfg.default_kind);

    recordEval(metrics, gpa, log_writer, start_ns, io, label == .unknown);

    if (label != .unknown) {
        cache.put(key, kind) catch |err| {
            logFailure(log_writer, "longevity.cache_write_failed", err);
        };
    }
    return kind;
}

fn recordEval(metrics: ?*metrics_mod.Metrics, gpa: std.mem.Allocator, log_writer: *std.Io.Writer, start_ns: i128, io: std.Io, failed: bool) void {
    const m = metrics orelse return;
    const elapsed_ns: u64 = @intCast(@max(std.Io.Clock.now(.awake, io).toNanoseconds() - start_ns, 0));
    m.recordPiEval(gpa, elapsed_ns, failed) catch |err| {
        // Recording failure is non-fatal (spec: "A recording failure SHALL
        // be non-fatal: it SHALL be logged..."). The classification outcome
        // is the source of truth; we log the failure so the operator sees
        // the registry is starved.
        logFailure(log_writer, "longevity.metrics_record_failed", err);
    };
}

fn logFailure(log_writer: *std.Io.Writer, event: []const u8, err: anyerror) void {
    log_mod.writeLine(log_writer, .warn, event, &.{
        .{ .key = "err", .value = @errorName(err) },
    }) catch {};
}

/// Real subprocess invoker: spawns `pi -p "<prompt>" --no-tools --no-context-files
/// --no-session [--model <model>]` and returns stdout. Returns
/// `error.PiNonZeroExit` on a non-zero exit, a read error, or a timeout;
/// `error.PiNotFound` if the binary can't be started. The wall-clock bound
/// is `cfg.timeout_seconds`; a `pi` that overruns it is killed and reported
/// as an error (so `classify` routes it through the existing fallback).
/// Opt-in manual test only; the default test suite exercises the
/// parse/cache/fallback logic via stubbed `Invoker`s.
///
/// ponytail: timeout enforced via std.process.run's per-read timeout +
/// defer child.kill; one bound per invocation. Move to a pi --model batch
/// or persistent session if per-item spawn+timeout overhead matters at
/// high item counts.
pub fn productionInvoker(gpa: std.mem.Allocator, io: std.Io, cfg: PiConfig, rendered_prompt: []const u8) anyerror![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, cfg.path);
    try argv.append(gpa, "-p");
    try argv.append(gpa, rendered_prompt);
    try argv.append(gpa, "--no-tools");
    try argv.append(gpa, "--no-context-files");
    try argv.append(gpa, "--no-session");
    if (cfg.model) |m| {
        try argv.append(gpa, "--model");
        try argv.append(gpa, m);
    }

    const timeout: std.Io.Timeout = if (cfg.timeout_seconds) |s| .{
        .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromSeconds(s) },
    } else .none;

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1 << 20),
        .timeout = timeout,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.PiNotFound,
        else => return error.PiNonZeroExit,
    };
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return error.PiNonZeroExit;
        },
        else => {
            gpa.free(result.stdout);
            return error.PiNonZeroExit;
        },
    }
    return result.stdout;
}

/// Resolve the default cache file path under `$XDG_CACHE_HOME/curation/`.
pub fn defaultCachePath(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |xdg| {
        const slice = std.mem.sliceTo(xdg, 0);
        return std.fs.path.join(gpa, &[_][]const u8{ slice, "curation", "eval-cache.json" });
    }
    if (std.c.getenv("HOME")) |home| {
        const slice = std.mem.sliceTo(home, 0);
        return std.fs.path.join(gpa, &[_][]const u8{ slice, ".cache", "curation", "eval-cache.json" });
    }
    return gpa.dupe(u8, "curation/eval-cache.json");
}

// ============= tests =============

test "labelToKind: short_term → news" {
    try std.testing.expectEqual(Kind.news, labelToKind(.short_term, .knowledge));
}

test "labelToKind: long_term → knowledge" {
    try std.testing.expectEqual(Kind.knowledge, labelToKind(.long_term, .news));
}

test "labelToKind: unknown falls back to default (news)" {
    try std.testing.expectEqual(Kind.news, labelToKind(.unknown, .news));
}

test "labelToKind: unknown falls back to default (knowledge)" {
    try std.testing.expectEqual(Kind.knowledge, labelToKind(.unknown, .knowledge));
}

test "parseLabel: short_term accepted" {
    try std.testing.expectEqual(Label.short_term, parseLabel("short_term"));
}

test "parseLabel: long_term accepted" {
    try std.testing.expectEqual(Label.long_term, parseLabel("long_term"));
}

test "parseLabel: SHORT_TERM accepted case-insensitively" {
    try std.testing.expectEqual(Label.short_term, parseLabel("SHORT_TERM"));
}

test "parseLabel: LONG_TERM accepted case-insensitively" {
    try std.testing.expectEqual(Label.long_term, parseLabel("LONG_TERM"));
}

test "parseLabel: MixedCase accepted" {
    try std.testing.expectEqual(Label.long_term, parseLabel("Long_Term"));
}

test "parseLabel: first valid token wins" {
    try std.testing.expectEqual(Label.long_term, parseLabel("some prose long_term more stuff"));
}

test "parseLabel: empty → unknown" {
    try std.testing.expectEqual(Label.unknown, parseLabel(""));
}

test "parseLabel: prose → unknown" {
    try std.testing.expectEqual(Label.unknown, parseLabel("I think this is probably news"));
}

test "parseLabel: hyphenated short-term → unknown" {
    try std.testing.expectEqual(Label.unknown, parseLabel("short-term"));
}

test "parseLabel: hyphenated long-term → unknown" {
    try std.testing.expectEqual(Label.unknown, parseLabel("long-term"));
}

test "parseLabel: JSON string → unknown" {
    try std.testing.expectEqual(Label.unknown, parseLabel("\"short_term\""));
}

test "parseLabel: token embedded in identifier → unknown" {
    try std.testing.expectEqual(Label.unknown, parseLabel("short_terminal"));
}

test "sha256Hex: 64 hex chars" {
    const gpa = std.testing.allocator;
    const hex = try sha256Hex(gpa, "hello", "world");
    defer gpa.free(hex);
    try std.testing.expectEqual(@as(usize, 64), hex.len);
    for (hex) |c| try std.testing.expect(std.ascii.isHex(c));
}

test "sha256Hex: deterministic" {
    const gpa = std.testing.allocator;
    const a = try sha256Hex(gpa, "hello", "world");
    defer gpa.free(a);
    const b = try sha256Hex(gpa, "hello", "world");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "sha256Hex: distinct inputs → distinct hashes" {
    const gpa = std.testing.allocator;
    const a = try sha256Hex(gpa, "hello", "world");
    defer gpa.free(a);
    const b = try sha256Hex(gpa, "hello", "WORLD");
    defer gpa.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "sha256Hex: empty title+body" {
    const gpa = std.testing.allocator;
    const hex = try sha256Hex(gpa, "", "");
    defer gpa.free(hex);
    try std.testing.expectEqual(@as(usize, 64), hex.len);
}

test "renderPrompt: replaces {title} and {body}" {
    const gpa = std.testing.allocator;
    const rendered = try renderPrompt(gpa, "Title: {title}\nBody: {body}", "My Title", "My Body");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("Title: My Title\nBody: My Body", rendered);
}

test "renderPrompt: replaces {title} first to preserve {title} in body value" {
    const gpa = std.testing.allocator;
    const rendered = try renderPrompt(gpa, "{title}|{body}", "T", "{title}");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("T|{title}", rendered);
}

test "renderPrompt: no placeholders returns the template" {
    const gpa = std.testing.allocator;
    const rendered = try renderPrompt(gpa, "static text", "x", "y");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("static text", rendered);
}

test "renderPrompt: empty title and body" {
    const gpa = std.testing.allocator;
    const rendered = try renderPrompt(gpa, "{title}/{body}", "", "");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("/", rendered);
}

test "EvalCache: lookup returns null on miss" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-miss.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
    var c = try EvalCache.load(gpa, std.testing.io, tmp);
    defer c.deinit();
    try std.testing.expect(c.lookup("deadbeef") == null);
}

test "EvalCache: put then lookup round-trip" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-put.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
    var c = try EvalCache.load(gpa, std.testing.io, tmp);
    defer c.deinit();
    try c.put("abc", .knowledge);
    try std.testing.expectEqual(@as(?Kind, .knowledge), c.lookup("abc"));
}

test "EvalCache: save then reload from file round-trips" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-roundtrip.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
    {
        var c = try EvalCache.load(gpa, std.testing.io, tmp);
        defer c.deinit();
        try c.put("aabbcc", .news);
        try c.put("ddeeff", .knowledge);
        try c.save();
    }
    {
        var c = try EvalCache.load(gpa, std.testing.io, tmp);
        defer c.deinit();
        try std.testing.expectEqual(@as(?Kind, .news), c.lookup("aabbcc"));
        try std.testing.expectEqual(@as(?Kind, .knowledge), c.lookup("ddeeff"));
    }
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "EvalCache: load from missing file returns empty cache" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-missing.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
    var c = try EvalCache.load(gpa, std.testing.io, tmp);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.map.count());
}

// ---- classify orchestrator with stub invokers ----

const StubState = struct {
    calls: u32 = 0,
    err: ?anyerror = null,
    payload: []const u8 = "",
};

fn stubInvokeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, _: std.Io, _: PiConfig, _: []const u8) anyerror![]u8 {
    const state: *StubState = @ptrCast(@alignCast(ctx));
    state.calls += 1;
    if (state.err) |e| return e;
    return gpa.dupe(u8, state.payload);
}

fn stubInvoker(state: *StubState) Invoker {
    return .{ .ctx = @ptrCast(state), .invoke = stubInvokeImpl };
}

test "classify: cache miss + long_term stub → knowledge, invoke called, cached" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-classify.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cache = try EvalCache.load(gpa, std.testing.io, tmp);
    defer cache.deinit();

    var state: StubState = .{ .payload = "long_term" };

    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const kind = classify(gpa, std.testing.io, "T", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, null);
    try std.testing.expectEqual(Kind.knowledge, kind);
    try std.testing.expectEqual(@as(u32, 1), state.calls);

    // Cached: a second call should not invoke.
    _ = classify(gpa, std.testing.io, "T", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, null);
    try std.testing.expectEqual(@as(u32, 1), state.calls); // no second invoke

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "classify: short_term stub → news" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-short.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cache = try EvalCache.load(gpa, std.testing.io, tmp);
    defer cache.deinit();

    var state: StubState = .{ .payload = "short_term" };

    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const kind = classify(gpa, std.testing.io, "A", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, null);
    try std.testing.expectEqual(Kind.news, kind);

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "classify: invoke error → default kind, logged, non-fatal, not cached" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-err.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cache = try EvalCache.load(gpa, std.testing.io, tmp);
    defer cache.deinit();

    var state: StubState = .{ .err = error.PiNonZeroExit };

    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const kind = classify(gpa, std.testing.io, "T", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, null);
    try std.testing.expectEqual(Kind.news, kind); // default
    try std.testing.expect(state.calls == 1);

    // Failure must NOT be cached — re-run retries.
    _ = classify(gpa, std.testing.io, "T", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, null);
    try std.testing.expectEqual(@as(u32, 2), state.calls); // retried

    // Failure logged at WARN.
    try std.testing.expect(std.mem.indexOf(u8, log_aw.written(), "level=warn") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_aw.written(), "longevity.invoke_failed") != null);

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "classify: garbage pi output → unknown → default kind, logged, not cached" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-garbage.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cache = try EvalCache.load(gpa, std.testing.io, tmp);
    defer cache.deinit();

    var state: StubState = .{ .payload = "I think this is probably news" };

    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const kind = classify(gpa, std.testing.io, "T", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, null);
    try std.testing.expectEqual(Kind.news, kind); // default

    // Garbage is not cached — re-run retries.
    _ = classify(gpa, std.testing.io, "T", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, null);
    try std.testing.expectEqual(@as(u32, 2), state.calls); // retried

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "classify: custom default_kind is honored on failure" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-custom-default.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cache = try EvalCache.load(gpa, std.testing.io, tmp);
    defer cache.deinit();

    var state: StubState = .{ .err = error.PiNotFound };

    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const cfg = PiConfig{ .default_kind = .knowledge };
    const kind = classify(gpa, std.testing.io, "T", "B", cfg, stubInvoker(&state), &cache, &log_aw.writer, null);
    try std.testing.expectEqual(Kind.knowledge, kind);

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "classify: successful classification is cached and survives a restart" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-restart.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var state: StubState = .{ .payload = "long_term" };

    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    {
        var cache = try EvalCache.load(gpa, std.testing.io, tmp);
        defer cache.deinit();
        _ = classify(gpa, std.testing.io, "T", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, null);
        try cache.save();
    }

    // Restart: new cache from same file.
    var state2: StubState = .{ .err = error.PiNotFound };
    var log_aw2: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw2.deinit();
    {
        var cache = try EvalCache.load(gpa, std.testing.io, tmp);
        defer cache.deinit();
        // Even though pi is now "broken", a cached item short-circuits to its
        // cached kind without invoking.
        const kind = classify(gpa, std.testing.io, "T", "B", .{}, stubInvoker(&state2), &cache, &log_aw2.writer, null);
        try std.testing.expectEqual(Kind.knowledge, kind);
        try std.testing.expectEqual(@as(u32, 0), state2.calls); // never invoked
    }

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "classify: cache-miss + parseable response records one evaluation, one sample, zero failures" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-metrics-ok.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cache = try EvalCache.load(gpa, std.testing.io, tmp);
    defer cache.deinit();

    var state: StubState = .{ .payload = "long_term" };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    const kind = classify(gpa, std.testing.io, "Metrics-OK", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, &m);
    try std.testing.expectEqual(Kind.knowledge, kind);

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_failed_total 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluation_duration_seconds_count 1") != null);

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "classify: invoke error records one evaluation and one failure" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-metrics-err.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cache = try EvalCache.load(gpa, std.testing.io, tmp);
    defer cache.deinit();

    var state: StubState = .{ .err = error.PiNonZeroExit };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    const kind = classify(gpa, std.testing.io, "Metrics-Err", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, &m);
    try std.testing.expectEqual(Kind.news, kind); // default

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_failed_total 1") != null);

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "classify: unparseable result records one evaluation and one failure" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-metrics-unknown.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cache = try EvalCache.load(gpa, std.testing.io, tmp);
    defer cache.deinit();

    var state: StubState = .{ .payload = "I think this is probably news" };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    const kind = classify(gpa, std.testing.io, "Metrics-Unk", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, &m);
    try std.testing.expectEqual(Kind.news, kind);

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_failed_total 1") != null);

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "classify: cache hit records nothing in the metrics" {
    const gpa = std.testing.allocator;
    const tmp = "zig-cache/tmp/eval-cache-metrics-hit.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cache = try EvalCache.load(gpa, std.testing.io, tmp);
    defer cache.deinit();

    var state: StubState = .{ .payload = "long_term" };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    // First call invokes and records.
    _ = classify(gpa, std.testing.io, "Same-Item", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, &m);
    // Second call should hit the cache and not record anything.
    _ = classify(gpa, std.testing.io, "Same-Item", "B", .{}, stubInvoker(&state), &cache, &log_aw.writer, &m);

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    // Only one invocation happened.
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluation_duration_seconds_count 1") != null);

    std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};
}

test "defaultCachePath: ends with eval-cache.json" {
    const gpa = std.testing.allocator;
    const path = try defaultCachePath(gpa);
    defer gpa.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "curation/eval-cache.json"));
}

test "PiConfig: defaults" {
    const c: PiConfig = .{};
    try std.testing.expectEqualStrings("pi", c.path);
    try std.testing.expect(c.model == null);
    try std.testing.expectEqualStrings(default_prompt, c.prompt);
    try std.testing.expectEqual(Kind.news, c.default_kind);
    try std.testing.expectEqual(@as(?u32, 30), c.timeout_seconds);
}

// ---- productionInvoker: stub-subprocess regression (longevity capability) ----
//
// Mirrors the render.zig pattern: a tiny shell stub written into
// zig-cache/tmp/ that is invoked via the real productionInvoker, against
// `std.testing.io` (a real Io.Threaded, which honours pipe-read timeouts).
// The "sleep-forever" stub proves the timeout is enforced end-to-end: the
// call returns an error within the bound instead of hanging on
// `child.wait(io)` (the regression this test guards against).
const PI_STUB_SCRIPT_PATH = "zig-cache/tmp/longevity-pi-stub.sh";
// Ignores argv; sleeps until SIGTERM. Forces run()'s first read to time out.
const PI_STUB_SCRIPT_CONTENT =
    \\#!/bin/sh
    \\sleep 60
    \\exit 0
;

fn writePiStubScript() !void {
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, PI_STUB_SCRIPT_PATH, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, PI_STUB_SCRIPT_CONTENT);
    }
    const perm: std.Io.File.Permissions = @enumFromInt(0o755);
    try std.Io.Dir.setFilePermissions(.cwd(), std.testing.io, PI_STUB_SCRIPT_PATH, perm, .{});
}

test "productionInvoker: timed-out subprocess returns an error within the timeout" {
    try writePiStubScript();
    const gpa = std.testing.allocator;
    const cfg: PiConfig = .{ .path = PI_STUB_SCRIPT_PATH, .timeout_seconds = 1 };
    if (productionInvoker(gpa, std.testing.io, cfg, "irrelevant")) |stdout| {
        defer gpa.free(stdout);
        return error.ShouldHaveFailed;
    } else |err| {
        try std.testing.expectEqual(error.PiNonZeroExit, err);
    }
}

test "productionInvoker: missing binary returns PiNotFound" {
    const gpa = std.testing.allocator;
    const cfg: PiConfig = .{ .path = "/nonexistent/pi-binary-path", .timeout_seconds = 1 };
    if (productionInvoker(gpa, std.testing.io, cfg, "irrelevant")) |stdout| {
        defer gpa.free(stdout);
        return error.ShouldHaveFailed;
    } else |err| {
        try std.testing.expectEqual(error.PiNotFound, err);
    }
}
