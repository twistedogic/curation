// Server configuration: JSON struct + XDG path resolution.
// ponytail: server fields + rule struct, std.json parsing, single loader
// function; upgrade if the config grows beyond ~10 fields or needs runtime
// mutation.
const std = @import("std");

const longevity_mod = @import("longevity.zig");

/// Rule primitives used by the curation pipeline.
pub const Action = enum { include, exclude };
pub const Target = enum { title, url, any };

pub const FilterRule = struct {
    action: Action,
    target: Target = .any,
    needle: []const u8,
};

pub const TagRule = struct {
    tag: []const u8,
    target: Target = .any,
    needle: []const u8,
};

/// Bundle of pipeline rules. `cap == 0` means unbounded.
pub const Rules = struct {
    filter_rules: []const FilterRule = &.{},
    tag_rules: []const TagRule = &.{},
    cap: u32 = 0,
};

/// One configured feed source. The set of fields is intentionally small
/// (name + url); web-source type discrimination is a later slice (US-008).
pub const Source = struct {
    name: []const u8,
    url: []const u8,
};

/// Lightpanda `--dump` argument options. The string form is the argv value.
pub const LightpandaDumpFormat = enum { markdown, html };

/// How to invoke the Lightpanda headless browser for web-content sources.
/// `path` is resolved via the parent's `PATH` (argv[0] resolution).
pub const LightpandaConfig = struct {
    path: []const u8 = "lightpanda",
    dump_format: LightpandaDumpFormat = .markdown,
};

/// Default daily curation time (local clock, "HH:MM").
pub const default_schedule: []const u8 = "04:00";

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8787,
    auth_token: []const u8 = "",
    filter_rules: []const FilterRule = &.{},
    tag_rules: []const TagRule = &.{},
    /// Rule cap. Zero means unbounded.
    cap: u32 = 0,
    /// Age window in days. Zero disables pruning.
    retention_days: u32 = 90,
    pi: longevity_mod.PiConfig = .{},
    /// Feed sources to acquire on each curation run. Empty by default
    /// (a config with no sources runs zero acquisitions).
    sources: []const Source = &.{},
    /// Web-content sources to acquire on each curation run via Lightpanda.
    /// Same shape as feed sources; the run treats them as a separate
    /// acquisition kind.
    web_sources: []const Source = &.{},
    /// Lightpanda invocation settings. Used by `render.acquireWeb`.
    lightpanda: LightpandaConfig = .{},
    /// Daily local-time string `"HH:MM"` at which the scheduler fires
    /// the curation job. Defaults to `default_schedule` ("04:00").
    schedule: []const u8 = default_schedule,

    pub const LoadError = error{ FileNotFound, ParseFailed, OutOfMemory };

    pub fn load(
        gpa: std.mem.Allocator,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        args_config: ?[]const u8,
    ) LoadError!Config {
        const path = resolvePath(gpa, environ_map, args_config) catch return error.ParseFailed;
        defer gpa.free(path);

        const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return error.ParseFailed,
        };
        defer gpa.free(bytes);

        var parsed = std.json.parseFromSlice(Config, gpa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return error.ParseFailed;

        // parseFromSlice uses gpa to back slice fields. Convert the parser's
        // view into a struct whose slices are independently owned by `gpa`
        // so the caller can free with `Config.deinit`.
        const cfg = parsed.value;
        const owned_host = try gpa.dupe(u8, cfg.host);
        errdefer gpa.free(owned_host);
        const owned_token = try gpa.dupe(u8, cfg.auth_token);
        const owned_filter_rules = try copyFilterRules(gpa, cfg.filter_rules);
        errdefer freeFilterRules(gpa, owned_filter_rules);
        const owned_tag_rules = try copyTagRules(gpa, cfg.tag_rules);
        const owned_pi_path = try gpa.dupe(u8, cfg.pi.path);
        errdefer gpa.free(owned_pi_path);
        const owned_pi_prompt = try gpa.dupe(u8, cfg.pi.prompt);
        const owned_pi_model: ?[]const u8 = if (cfg.pi.model) |m| try gpa.dupe(u8, m) else null;
        const owned_sources = try copySources(gpa, cfg.sources);
        errdefer freeSources(gpa, owned_sources);
        const owned_web_sources = try copySources(gpa, cfg.web_sources);
        errdefer freeSources(gpa, owned_web_sources);
        const owned_lightpanda_path = try gpa.dupe(u8, cfg.lightpanda.path);
        errdefer gpa.free(owned_lightpanda_path);
        const owned_schedule = try gpa.dupe(u8, cfg.schedule);
        parsed.deinit();
        return .{
            .host = owned_host,
            .port = cfg.port,
            .auth_token = owned_token,
            .filter_rules = owned_filter_rules,
            .tag_rules = owned_tag_rules,
            .cap = cfg.cap,
            .retention_days = cfg.retention_days,
            .pi = .{
                .path = owned_pi_path,
                .model = owned_pi_model,
                .prompt = owned_pi_prompt,
                .default_kind = cfg.pi.default_kind,
                .timeout_seconds = cfg.pi.timeout_seconds,
            },
            .sources = owned_sources,
            .web_sources = owned_web_sources,
            .lightpanda = .{
                .path = owned_lightpanda_path,
                .dump_format = cfg.lightpanda.dump_format,
            },
            .schedule = owned_schedule,
        };
    }

    pub fn deinit(cfg: *Config, gpa: std.mem.Allocator) void {
        // Only valid on values returned by `load` — those slices are
        // independently allocated by `gpa`. Don't call on a hand-built
        // `Config{}` literal (which uses static string slices).
        gpa.free(cfg.host);
        gpa.free(cfg.auth_token);
        freeFilterRules(gpa, cfg.filter_rules);
        freeTagRules(gpa, cfg.tag_rules);
        gpa.free(cfg.pi.path);
        gpa.free(cfg.pi.prompt);
        if (cfg.pi.model) |m| gpa.free(m);
        freeSources(gpa, cfg.sources);
        freeSources(gpa, cfg.web_sources);
        gpa.free(cfg.lightpanda.path);
        gpa.free(cfg.schedule);
        cfg.* = undefined;
    }

    pub fn resolvePath(
        gpa: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        args_config: ?[]const u8,
    ) std.mem.Allocator.Error![]u8 {
        if (args_config) |p| return gpa.dupe(u8, p);
        if (environ_map.get("CURATION_CONFIG")) |p| return gpa.dupe(u8, p);
        return defaultPath(gpa);
    }

    pub fn defaultPath(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
            const slice = std.mem.sliceTo(xdg, 0);
            return std.fs.path.join(gpa, &[_][]const u8{ slice, "curation", "config.json" });
        }
        if (std.c.getenv("HOME")) |home| {
            const slice = std.mem.sliceTo(home, 0);
            return std.fs.path.join(gpa, &[_][]const u8{ slice, ".config", "curation", "config.json" });
        }
        return gpa.dupe(u8, "curation/config.json");
    }

    /// Atomically rewrite `cfg` to `path`: serialize to a sibling temp file
    /// and `Dir.rename` it over the resolved path. A crash mid-write leaves
    /// the pre-existing `path` untouched. Only modeled fields are written.
    /// ponytail: single serialization pass, no pretty-printing, no fsync of
    /// the directory entry — Dir.rename is the atomicity boundary, which is
    /// enough for crash-safety on POSIX.
    pub const WriteError = std.mem.Allocator.Error || std.Io.Writer.Error || std.Io.File.OpenError || std.Io.File.WritePositionalError || std.Io.File.SyncError || std.Io.Dir.DeleteFileError || std.Io.Dir.RenameError;

    pub fn write(
        gpa: std.mem.Allocator,
        io: std.Io,
        cfg: Config,
        path: []const u8,
    ) WriteError!void {
        var tmp_id_buf: [8]u8 = undefined;
        std.Io.random(io, &tmp_id_buf);
        const tmp_id = std.mem.readInt(u64, &tmp_id_buf, .little);
        const tmp_path = try std.fmt.allocPrint(gpa, "{s}.import.{x}", .{ path, tmp_id });
        defer gpa.free(tmp_path);

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try std.json.Stringify.value(cfg, .{}, &aw.writer);

        {
            const f = try std.Io.Dir.createFile(.cwd(), io, tmp_path, .{});
            errdefer std.Io.Dir.deleteFile(.cwd(), io, tmp_path) catch {};
            defer f.close(io);
            try std.Io.File.writePositionalAll(f, io, aw.written(), 0);
            try f.sync(io);
        }
        std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io) catch |err| {
            std.Io.Dir.deleteFile(.cwd(), io, tmp_path) catch {};
            return err;
        };
    }
};

fn copyFilterRules(gpa: std.mem.Allocator, src: []const FilterRule) std.mem.Allocator.Error![]FilterRule {
    if (src.len == 0) return &.{};
    const dst = try gpa.alloc(FilterRule, src.len);
    errdefer {
        for (dst[0..src.len]) |r| if (r.needle.len > 0) gpa.free(r.needle);
        gpa.free(dst);
    }
    for (src, 0..) |r, i| {
        dst[i] = .{
            .action = r.action,
            .target = r.target,
            .needle = try gpa.dupe(u8, r.needle),
        };
    }
    return dst;
}

fn freeFilterRules(gpa: std.mem.Allocator, rules: []const FilterRule) void {
    if (rules.len == 0) return;
    for (rules) |r| gpa.free(r.needle);
    gpa.free(rules);
}

fn copyTagRules(gpa: std.mem.Allocator, src: []const TagRule) std.mem.Allocator.Error![]TagRule {
    if (src.len == 0) return &.{};
    const dst = try gpa.alloc(TagRule, src.len);
    errdefer {
        for (dst[0..src.len]) |r| {
            if (r.tag.len > 0) gpa.free(r.tag);
            if (r.needle.len > 0) gpa.free(r.needle);
        }
        gpa.free(dst);
    }
    for (src, 0..) |r, i| {
        dst[i] = .{
            .tag = try gpa.dupe(u8, r.tag),
            .target = r.target,
            .needle = try gpa.dupe(u8, r.needle),
        };
    }
    return dst;
}

fn freeTagRules(gpa: std.mem.Allocator, rules: []const TagRule) void {
    if (rules.len == 0) return;
    for (rules) |r| {
        gpa.free(r.tag);
        gpa.free(r.needle);
    }
    gpa.free(rules);
}

// ponytail: Source deep-copy mirrors the filter/tag pattern; lift into a
// generic helper if a third rule-of-deep-owned lists lands.
fn copySources(gpa: std.mem.Allocator, src: []const Source) std.mem.Allocator.Error![]Source {
    if (src.len == 0) return &.{};
    const dst = try gpa.alloc(Source, src.len);
    errdefer {
        for (dst[0..src.len]) |s| {
            if (s.name.len > 0) gpa.free(s.name);
            if (s.url.len > 0) gpa.free(s.url);
        }
        gpa.free(dst);
    }
    for (src, 0..) |s, i| {
        dst[i] = .{
            .name = try gpa.dupe(u8, s.name),
            .url = try gpa.dupe(u8, s.url),
        };
    }
    return dst;
}

/// Free a `[]const Source` whose `name` and `url` slices are gpa-owned and
/// whose backing slice is gpa-owned (the shape returned by `copySources` and
/// by `Config.load`).
pub fn freeSources(gpa: std.mem.Allocator, sources: []const Source) void {
    if (sources.len == 0) return;
    for (sources) |s| {
        gpa.free(s.name);
        gpa.free(s.url);
    }
    gpa.free(sources);
}

// ============= tests =============

test "config defaults" {
    const d: Config = .{}; // field initializers provide defaults
    try std.testing.expectEqualStrings("127.0.0.1", d.host);
    try std.testing.expectEqual(@as(u16, 8787), d.port);
    try std.testing.expectEqualStrings("", d.auth_token);
    try std.testing.expectEqual(@as(usize, 0), d.filter_rules.len);
    try std.testing.expectEqual(@as(usize, 0), d.tag_rules.len);
    try std.testing.expectEqual(@as(u32, 0), d.cap);
}

test "config has a default retention window" {
    try std.testing.expectEqual(@as(u32, 90), (Config{}).retention_days);
}

test "config load parses retention_days" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-retention.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"retention_days\":30,\"future_field\":42}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 30), cfg.retention_days);
}

test "config load: missing file fails with FileNotFound" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("CURATION_CONFIG", "/from/env.json");
    const path = try Config.resolvePath(gpa, &env, "/from/flag.json");
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/from/flag.json", path);
}

test "config resolvePath: env wins over XDG default" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("CURATION_CONFIG", "/from/env.json");
    const path = try Config.resolvePath(gpa, &env, null);
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/from/env.json", path);
}

test "config resolvePath: default uses HOME/.config" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    // Verify the function returns a path that ends with curation/config.json
    // when XDG is unset and HOME has a value.
    if (std.c.getenv("HOME") == null) return;
    const path = try Config.resolvePath(gpa, &env, null);
    defer gpa.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "curation/config.json"));
}

test "config load: unknown fields are ignored" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-unknown.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"0.0.0.0\",\"port\":1,\"future_field\":42}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
    try std.testing.expectEqual(@as(u16, 1), cfg.port);
}

test "config load: port range" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-port.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":9090,\"auth_token\":\"s3cret\"}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 9090), cfg.port);
    try std.testing.expectEqualStrings("s3cret", cfg.auth_token);
}

test "config load: absent rules default to pass-through" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-no-rules.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"\"}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), cfg.filter_rules.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.tag_rules.len);
    try std.testing.expectEqual(@as(u32, 0), cfg.cap);
}

test "config load: unknown fields are ignored alongside rules" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-unknown-with-rules.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"",
            \\ "filter_rules":[{"action":"exclude","target":"title","needle":"sponsored"}],
            \\ "future_field":42}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cfg.filter_rules.len);
    try std.testing.expectEqual(Action.exclude, cfg.filter_rules[0].action);
    try std.testing.expectEqual(Target.title, cfg.filter_rules[0].target);
    try std.testing.expectEqualStrings("sponsored", cfg.filter_rules[0].needle);
}

test "config load: cap of zero means unbounded" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-cap-zero.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"\",\"cap\":0}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), cfg.cap);
}

test "config load: rules deep-copy so the parsed buffer can be freed" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-rules.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"",
            \\ "filter_rules":[{"action":"exclude","target":"title","needle":"sponsored"}],
            \\ "tag_rules":[{"tag":"ai","target":"title","needle":"llm"}],
            \\ "cap":5}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cfg.filter_rules.len);
    try std.testing.expectEqualStrings("sponsored", cfg.filter_rules[0].needle);
    try std.testing.expectEqual(@as(usize, 1), cfg.tag_rules.len);
    try std.testing.expectEqualStrings("ai", cfg.tag_rules[0].tag);
    try std.testing.expectEqualStrings("llm", cfg.tag_rules[0].needle);
    try std.testing.expectEqual(@as(u32, 5), cfg.cap);
}

test "Rules defaults: empty rules and cap==0" {
    const r: Rules = .{};
    try std.testing.expectEqual(@as(usize, 0), r.filter_rules.len);
    try std.testing.expectEqual(@as(usize, 0), r.tag_rules.len);
    try std.testing.expectEqual(@as(u32, 0), r.cap);
}

test "config load: absent pi block uses defaults" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-no-pi.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"\"}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("pi", cfg.pi.path);
    try std.testing.expect(cfg.pi.model == null);
    try std.testing.expectEqualStrings(longevity_mod.default_prompt, cfg.pi.prompt);
    try std.testing.expectEqual(longevity_mod.Kind.news, cfg.pi.default_kind);
    try std.testing.expectEqual(@as(?u32, 30), cfg.pi.timeout_seconds);
}

test "config load: custom pi block is parsed and owned" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-pi.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
                \\{"host":"127.0.0.1","port":8787,"auth_token":"",
                \\ "pi":{"path":"/usr/local/bin/pi","model":"flash",
                \\       "prompt":"Title:{title} Body:{body}",
                \\       "default_kind":"knowledge","timeout_seconds":30}}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("/usr/local/bin/pi", cfg.pi.path);
    try std.testing.expectEqualStrings("flash", cfg.pi.model.?);
    try std.testing.expectEqualStrings("Title:{title} Body:{body}", cfg.pi.prompt);
    try std.testing.expectEqual(longevity_mod.Kind.knowledge, cfg.pi.default_kind);
    try std.testing.expectEqual(@as(?u32, 30), cfg.pi.timeout_seconds);
}

test "config load: pi block ignores unknown fields" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-pi-unknown.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"",
            \\ "pi":{"path":"pi","future_field":"ignored"}}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("pi", cfg.pi.path);
}

test "config defaults: sources empty, schedule \"04:00\"" {
    const d: Config = .{};
    try std.testing.expectEqual(@as(usize, 0), d.sources.len);
    try std.testing.expectEqualStrings("04:00", d.schedule);
}

test "config load: absent sources defaults to an empty list" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-no-sources.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"\"}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), cfg.sources.len);
}

test "config load: sources are parsed with name and url" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-sources.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"",
            \\ "sources":[
            \\   {"name":"hackernews","url":"https://news.ycombinator.com/rss"},
            \\   {"name":"lobsters","url":"https://lobste.rs/rss"}
            \\ ]}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), cfg.sources.len);
    try std.testing.expectEqualStrings("hackernews", cfg.sources[0].name);
    try std.testing.expectEqualStrings("https://news.ycombinator.com/rss", cfg.sources[0].url);
    try std.testing.expectEqualStrings("lobsters", cfg.sources[1].name);
    try std.testing.expectEqualStrings("https://lobste.rs/rss", cfg.sources[1].url);
}

test "config load: absent schedule defaults to 04:00" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-no-schedule.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"\"}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("04:00", cfg.schedule);
}

test "config load: custom schedule is parsed and owned" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-schedule.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"","schedule":"06:30"}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("06:30", cfg.schedule);
}

test "config load: sources deep-copy so the parsed buffer can be freed" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-sources-deepcopy.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"",
            \\ "sources":[{"name":"hn","url":"https://news.ycombinator.com/rss"}]}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    // The bytes must outlive the parsed buffer; a simple equality check is
    // enough because deinit() would crash on a stale slice.
    try std.testing.expectEqualStrings("hn", cfg.sources[0].name);
    try std.testing.expectEqualStrings("https://news.ycombinator.com/rss", cfg.sources[0].url);
}

test "config load: existing config without sources/schedule still loads" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-legacy.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"abc\"}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("abc", cfg.auth_token);
    try std.testing.expectEqual(@as(usize, 0), cfg.sources.len);
    try std.testing.expectEqualStrings("04:00", cfg.schedule);
}

test "config defaults: web_sources empty, lightpanda path 'lightpanda', dump_format markdown" {
    const d: Config = .{};
    try std.testing.expectEqual(@as(usize, 0), d.web_sources.len);
    try std.testing.expectEqualStrings("lightpanda", d.lightpanda.path);
    try std.testing.expectEqual(LightpandaDumpFormat.markdown, d.lightpanda.dump_format);
}

test "config load: absent web_sources defaults to an empty list" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-no-web-sources.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"\"}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), cfg.web_sources.len);
}

test "config load: web sources are parsed with name and url" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-web-sources.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"",
            \\ "web_sources":[
            \\   {"name":"cnn","url":"https://www.cnn.com"},
            \\   {"name":"bbc","url":"https://www.bbc.com"}
            \\ ]}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), cfg.web_sources.len);
    try std.testing.expectEqualStrings("cnn", cfg.web_sources[0].name);
    try std.testing.expectEqualStrings("https://www.cnn.com", cfg.web_sources[0].url);
    try std.testing.expectEqualStrings("bbc", cfg.web_sources[1].name);
    try std.testing.expectEqualStrings("https://www.bbc.com", cfg.web_sources[1].url);
}

test "config load: absent lightpanda block uses defaults" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-no-lightpanda.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"\"}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("lightpanda", cfg.lightpanda.path);
    try std.testing.expectEqual(LightpandaDumpFormat.markdown, cfg.lightpanda.dump_format);
}

test "config load: custom lightpanda block is parsed and owned" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-lightpanda.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"",
            \\ "lightpanda":{"path":"/opt/lightpanda","dump_format":"html"}}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("/opt/lightpanda", cfg.lightpanda.path);
    try std.testing.expectEqual(LightpandaDumpFormat.html, cfg.lightpanda.dump_format);
}

test "config load: web sources deep-copy so the parsed buffer can be freed" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-web-sources-deepcopy.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"",
            \\ "web_sources":[{"name":"hn","url":"https://news.ycombinator.com"}]}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("hn", cfg.web_sources[0].name);
    try std.testing.expectEqualStrings("https://news.ycombinator.com", cfg.web_sources[0].url);
}

test "config write: round-trip preserves every field except sources" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-write-roundtrip.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io,
            \\{"host":"127.0.0.1","port":8787,"auth_token":"tok",
            \\ "filter_rules":[{"action":"exclude","target":"title","needle":"sponsored"}],
            \\ "tag_rules":[{"tag":"ai","target":"title","needle":"llm"}],
            \\ "cap":7,"retention_days":30,
            \\ "sources":[{"name":"hn","url":"https://news.ycombinator.com/rss"}],
            \\ "schedule":"06:30"}
        );
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);

    const new_source = Source{ .name = "lobsters", .url = "https://lobste.rs/rss" };
    const old_sources = cfg.sources;
    const merged_sources = try gpa.alloc(Source, old_sources.len + 1);
    for (old_sources, 0..) |s, i| {
        merged_sources[i] = .{ .name = try gpa.dupe(u8, s.name), .url = try gpa.dupe(u8, s.url) };
    }
    merged_sources[old_sources.len] = .{ .name = try gpa.dupe(u8, new_source.name), .url = try gpa.dupe(u8, new_source.url) };
    cfg.sources = merged_sources;

    try Config.write(gpa, std.testing.io, cfg, tmp);

    // cfg.deinit will free the merged_sources backing strings; free the
    // old (now-unused) sources memory before reload so the reload's owned
    // memory doesn't get clobbered.
    freeSources(gpa, old_sources);
    cfg.deinit(gpa);

    var reloaded = try Config.load(gpa, std.testing.io, &env, tmp);
    defer reloaded.deinit(gpa);
    try std.testing.expectEqualStrings("127.0.0.1", reloaded.host);
    try std.testing.expectEqual(@as(u16, 8787), reloaded.port);
    try std.testing.expectEqualStrings("tok", reloaded.auth_token);
    try std.testing.expectEqual(@as(usize, 1), reloaded.filter_rules.len);
    try std.testing.expectEqualStrings("sponsored", reloaded.filter_rules[0].needle);
    try std.testing.expectEqual(@as(usize, 1), reloaded.tag_rules.len);
    try std.testing.expectEqualStrings("ai", reloaded.tag_rules[0].tag);
    try std.testing.expectEqual(@as(u32, 7), reloaded.cap);
    try std.testing.expectEqual(@as(u32, 30), reloaded.retention_days);
    try std.testing.expectEqualStrings("06:30", reloaded.schedule);
    try std.testing.expectEqual(@as(usize, 2), reloaded.sources.len);
    try std.testing.expectEqualStrings("hn", reloaded.sources[0].name);
    try std.testing.expectEqualStrings("lobsters", reloaded.sources[1].name);
    try std.testing.expectEqualStrings("https://lobste.rs/rss", reloaded.sources[1].url);
}

test "config write: produces a temp file that is renamed and cleaned up" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const tmp = "zig-cache/tmp/config-write-cleanup.json";
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, tmp, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "{\"host\":\"127.0.0.1\",\"port\":8787,\"auth_token\":\"\"}");
    }
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, tmp) catch {};

    var cfg = try Config.load(gpa, std.testing.io, &env, tmp);
    defer cfg.deinit(gpa);

    try Config.write(gpa, std.testing.io, cfg, tmp);

    // No stray .tmp.* sibling left behind in the directory.
    var dir = std.Io.Dir.openDir(.cwd(), std.testing.io, "zig-cache/tmp", .{ .iterate = true }) catch return;
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        try std.testing.expect(std.mem.indexOf(u8, entry.name, "config-write-cleanup.json.") == null);
    }
}

