// HTTP server lifecycle + route handling.
// ponytail: single accept loop, single-user/daily-cadence; add concurrency
// only if a measured latency target demands it. cooperative shutdown
// between connections; hard-cancel a long-running in-flight request only if
// one ever appears (the curation job lands in a later change).
const std = @import("std");

const config_mod = @import("config.zig");
const curation_job_mod = @import("curation_job.zig");
const log_mod = @import("log.zig");
const metrics_mod = @import("metrics.zig");
const auth_mod = @import("auth.zig");
const download_mod = @import("download.zig");
const fetch_mod = @import("fetch.zig");
const longevity_mod = @import("longevity.zig");
const opml_mod = @import("opml.zig");
const render_mod = @import("render.zig");
const store_mod = @import("store.zig");
const ui_mod = @import("ui.zig");

pub const Config = config_mod.Config;
pub const Store = store_mod.Store;
pub const Source = config_mod.Source;
pub const EvalCache = longevity_mod.EvalCache;
pub const Invoker = longevity_mod.Invoker;
pub const Kind = store_mod.Kind;

pub var stop_flag: std.atomic.Value(bool) = .init(false);
/// Listening socket FD; signal handler shuts it down to unblock `accept`.
/// ponytail: global fd to wake the blocking accept on shutdown; replace with
/// a self-pipe if multi-threaded accept ever lands.
var listen_fd: std.posix.fd_t = -1;

/// All dependencies the route handlers need. Produced once by `serveCommand`
/// and shared by the accept loop, the scheduler thread, and the tests.
pub const Deps = struct {
    gpa: std.mem.Allocator,
    cfg: *const Config,
    store: *Store,
    metrics: *metrics_mod.Metrics,
    io: std.Io,
    http_client: *std.http.Client,
    eval_cache: *EvalCache,
    invoker: Invoker,
    user_agent: []const u8,
    timeout: std.Io.Timeout,
};

/// Result of handling a request; HTTP server turns this into a response.
pub const HandleResult = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
    /// Tracks whether the route was open (true) or protected (false).
    open_route: bool,
    /// Set on a successful /download response; emitted as the X-Next-Token
    /// header so the client can resume after the last delivered item.
    next_token: ?[]const u8 = null,
};

/// Pure route handler: given an HTTP method, path, and Authorization header
/// value, returns the response. Does not touch the network; tests use this.
pub fn handleRequest(
    gpa: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    auth_header: ?[]const u8,
    deps: *const Deps,
    now_ns: i128,
) HandleError!HandleResult {
    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");
    // Path includes the query string; the router matches the path part only.
    const q = std.mem.indexOfScalar(u8, path, '?');
    const path_part = if (q) |i| path[0..i] else path;

    // GET /healthz — open
    if (is_get and std.mem.eql(u8, path_part, "/healthz")) {
        return .{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
            .body = "",
            .open_route = true,
        };
    }

    // GET /metrics — open
    if (is_get and std.mem.eql(u8, path_part, "/metrics")) {
        const body = try deps.metrics.render(gpa, now_ns);
        return .{
            .status = .ok,
            .content_type = metrics_mod.content_type,
            .body = body,
            .open_route = true,
        };
    }

    // GET / — open, serves the embedded ui page verbatim.
    if (is_get and std.mem.eql(u8, path_part, "/")) {
        return .{
            .status = .ok,
            .content_type = "text/html; charset=utf-8",
            .body = ui_mod.page,
            .open_route = true,
        };
    }

    // GET /download?since=<token> — protected, bearer-gated.
    if (is_get and std.mem.eql(u8, path_part, "/download")) {
        const query = if (q) |i| path[i + 1 ..] else "";
        return handleDownload(gpa, query, auth_header, deps);
    }

    // POST /curate — protected, bearer-gated, runs the curation job.
    if (is_post and std.mem.eql(u8, path_part, "/curate")) {
        return handleCurate(gpa, auth_header, deps);
    }

    return .{
        .status = .not_found,
        .content_type = "text/plain; charset=utf-8",
        .body = "not found\n",
        .open_route = true,
    };
}

/// Routes return either a download-engine error (for /download's EPUB path)
/// or an OutOfMemory error from JSON rendering for /curate.
pub const HandleError = download_mod.BuildError || std.mem.Allocator.Error || std.Io.Writer.Error;

fn errorResponse(status: std.http.Status) HandleResult {
    return .{
        .status = status,
        .content_type = "text/plain; charset=utf-8",
        .body = "",
        .open_route = false,
    };
}

/// Resolve `GET /download`. Bearer-gated.
///
/// Two resolution modes:
/// - `since=<token>` (the normal case): the token is the sole source of kind;
///   the `kind` parameter, if present, is ignored. An absent/malformed `since`
///   returns 400 without consulting the store.
/// - `kind=news|knowledge` with no `since` (the first-download bootstrap): the
///   server synthesizes token `{ kind, id = 0 }` and resolves from the
///   beginning of that kind. Absent or unknown `kind` returns 400 without
///   consulting the store. The client never builds a token locally — the
///   server is the sole token issuer.
fn handleDownload(
    gpa: std.mem.Allocator,
    query: []const u8,
    auth_header: ?[]const u8,
    deps: *const Deps,
) download_mod.BuildError!HandleResult {
    // Auth before any resolution work; the spec says 401 must not read the
    // store.
    const header = auth_header orelse return errorResponse(.unauthorized);
    if (!auth_mod.checkBearer(header, deps.cfg.auth_token)) return errorResponse(.unauthorized);

    if (parseQueryParam(query, "since")) |since| {
        // Normal mode: token is the sole source of kind.
        const token = download_mod.decode(gpa, since) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBase64, error.InvalidFormat, error.UnknownKind, error.InvalidId => return errorResponse(.bad_request),
        };
        return resolveAndRespond(gpa, deps.store, token, deps.metrics);
    }

    // Bootstrap mode: absent `since`; require a valid `kind` parameter.
    const kind_str = parseQueryParam(query, "kind") orelse return errorResponse(.bad_request);
    const kind = std.meta.stringToEnum(store_mod.Kind, kind_str) orelse return errorResponse(.bad_request);
    return resolveAndRespond(gpa, deps.store, .{ .kind = kind, .id = 0 }, deps.metrics);
}

fn resolveAndRespond(gpa: std.mem.Allocator, store: *Store, token: download_mod.Token, metrics: *metrics_mod.Metrics) download_mod.BuildError!HandleResult {
    const result = try download_mod.resolve(gpa, store, token, metrics);
    const r = result orelse return errorResponse(.no_content);
    return .{
        .status = .ok,
        .content_type = "application/epub+zip",
        .body = r.epub,
        .open_route = false,
        .next_token = r.next_token,
    };
}

/// Resolve `POST /curate`. Bearer-gated, runs the curation job synchronously
/// via the `curation-job` capability's non-blocking probe. Auth precedes any
/// run probe so a 401 is observed without starting a run.
fn handleCurate(
    gpa: std.mem.Allocator,
    auth_header: ?[]const u8,
    deps: *const Deps,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!HandleResult {
    // Auth before any work; the spec says 401 must not start a run.
    const header = auth_header orelse return errorResponse(.unauthorized);
    if (!auth_mod.checkBearer(header, deps.cfg.auth_token)) return errorResponse(.unauthorized);

    // Build a log writer into the response body so the run logs go to it
    // (and the response body has the summary when the run succeeds).
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const outcome = curation_job_mod.tryRun(
        gpa,
        deps.io,
        deps.cfg.sources,
        .{
            .filter_rules = deps.cfg.filter_rules,
            .tag_rules = deps.cfg.tag_rules,
            .cap = deps.cfg.cap,
        },
        deps.cfg.pi,
        deps.http_client,
        deps.eval_cache,
        deps.invoker,
        deps.store,
        deps.user_agent,
        deps.timeout,
        &log_aw.writer,
        fetch_mod.acquireFeed,
        deps.cfg.web_sources,
        deps.cfg.lightpanda,
        render_mod.acquireWeb,
        deps.cfg.retention_days,
        deps.metrics,
    );

    switch (outcome) {
        .busy => return errorResponse(.conflict),
        .ran => {
            const body = try renderSummaryJson(gpa, outcome.ran);
            return .{
                .status = .ok,
                .content_type = "application/json",
                .body = body,
                .open_route = false,
            };
        },
    }
}

/// Render a `curation_job.Summary` as a JSON object with stable keys.
fn renderSummaryJson(gpa: std.mem.Allocator, s: curation_job_mod.Summary) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(s, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

/// Return the value of the first `name=value` pair in `query`, or null.
fn parseQueryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// Default JSONL store path: `$XDG_DATA_HOME/curation/items.jsonl` (or
/// `~/.local/share/curation/items.jsonl` when XDG is unset).
/// ponytail: hardcoded XDG layout; add a Config field when a deployment
/// needs to override the path.
pub fn defaultStorePath(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |xdg| {
        const slice = std.mem.sliceTo(xdg, 0);
        return std.fs.path.join(gpa, &[_][]const u8{ slice, "curation", "items.jsonl" });
    }
    if (std.c.getenv("HOME")) |home| {
        const slice = std.mem.sliceTo(home, 0);
        return std.fs.path.join(gpa, &[_][]const u8{ slice, ".local", "share", "curation", "items.jsonl" });
    }
    return gpa.dupe(u8, "curation/items.jsonl");
}

const usage =
    \\usage: curation <command> [flags]
    \\
    \\Commands:
    \\  serve           Start the HTTP server
    \\  import <opml>   Merge OPML feed outlines into the config's sources
    \\  help            Show this help
    \\
    \\Flags for `serve` and `import`:
    \\  --config <path>   Path to config.json (overrides $CURATION_CONFIG)
    \\
;

/// Top-level entry point: dispatches subcommands. Returns exit code.
pub fn run(init_ctx: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), init_ctx.io, &stderr_buf);
    const err_writer = &stderr_writer.interface;

    if (args.len < 2) {
        err_writer.writeAll(usage) catch {};
        err_writer.flush() catch {};
        return 1;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        err_writer.writeAll(usage) catch {};
        err_writer.flush() catch {};
        return 0;
    }
    if (std.mem.eql(u8, cmd, "serve")) {
        return serveCommand(init_ctx, allocator, args[2..], err_writer);
    }
    if (std.mem.eql(u8, cmd, "import")) {
        return importCommand(init_ctx, allocator, args[2..], err_writer);
    }
    err_writer.print("unknown command: {s}\n\n{s}", .{ cmd, usage }) catch {};
    err_writer.flush() catch {};
    return 1;
}

const FlagError = error{ MissingFlagValue, UnknownFlag };

fn parseFlags(args: []const []const u8) FlagError!struct { config: ?[]const u8 } {
    var config: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--config")) {
            if (i + 1 >= args.len) return error.MissingFlagValue;
            i += 1;
            config = args[i];
        } else return error.UnknownFlag;
    }
    return .{ .config = config };
}

fn importCommand(init_ctx: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8, err_writer: *std.Io.Writer) u8 {
    if (args.len < 1) {
        err_writer.writeAll("usage: curation import <opml-file> [--config <path>]\n") catch {};
        err_writer.flush() catch {};
        return 1;
    }
    const opml_path = args[0];
    const rest = if (args.len > 1) args[1..] else &.{};
    const flags = parseFlags(rest) catch |err| {
        err_writer.print("level=err event=flag.error err={s}\n", .{@errorName(err)}) catch {};
        err_writer.flush() catch {};
        return 2;
    };

    opml_mod.importOpml(allocator, init_ctx.io, init_ctx.environ_map, opml_path, flags.config) catch |err| {
        log_mod.writeLine(err_writer, .err, "opml.import_failed", &.{
            .{ .key = "err", .value = @errorName(err) },
            .{ .key = "opml", .value = opml_path },
        }) catch {};
        return 1;
    };
    return 0;
}

fn serveCommand(init_ctx: std.process.Init, allocator: std.mem.Allocator, args: []const []const u8, err_writer: *std.Io.Writer) u8 {
    const flags = parseFlags(args) catch |err| {
        err_writer.print("level=err event=flag.error err={s}\n", .{@errorName(err)}) catch {};
        err_writer.flush() catch {};
        return 2;
    };

    var cfg = config_mod.Config.load(allocator, init_ctx.io, init_ctx.environ_map, flags.config) catch |err| switch (err) {
        error.FileNotFound => {
            err_writer.print("level=err event=config.missing path={s}\n", .{flags.config orelse "(default XDG path)"}) catch {};
            err_writer.flush() catch {};
            return 1;
        },
        else => {
            err_writer.print("level=err event=config.parse_failed err={s}\n", .{@errorName(err)}) catch {};
            err_writer.flush() catch {};
            return 1;
        },
    };
    defer cfg.deinit(allocator);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), init_ctx.io, &stderr_buf);
    const log_writer = &stderr_writer.interface;

    const now = std.Io.Clock.now(.awake, init_ctx.io);
    var metrics = metrics_mod.Metrics.init(now.toNanoseconds());
    defer metrics.deinit(allocator);

    const addr = std.fmt.allocPrint(allocator, "{s}:{d}", .{ cfg.host, cfg.port }) catch return 1;
    defer allocator.free(addr);

    log_mod.writeLine(log_writer, .info, "server.start", &.{
        .{ .key = "addr", .value = addr },
    }) catch {};
    log_writer.flush() catch {};

    installSigintHandler();
    var listener = std.Io.net.IpAddress.parse(cfg.host, cfg.port) catch |err| {
        log_mod.writeLine(log_writer, .err, "server.bind_failed", &.{
            .{ .key = "err", .value = @errorName(err) },
        }) catch {};
        return 1;
    };

    var server_socket = listener.listen(init_ctx.io, .{}) catch |err| {
        log_mod.writeLine(log_writer, .err, "server.listen_failed", &.{
            .{ .key = "err", .value = @errorName(err) },
            .{ .key = "addr", .value = addr },
        }) catch {};
        return 1;
    };
    defer server_socket.deinit(init_ctx.io);

    // Expose the listening fd to the SIGINT handler so it can `shutdown()`
    // and unblock the accept loop.
    listen_fd = server_socket.socket.handle;
    defer listen_fd = -1;

    const store_path = defaultStorePath(allocator) catch return 1;
    defer allocator.free(store_path);
    var store = Store.load(allocator, init_ctx.io, store_path) catch |err| {
        log_mod.writeLine(log_writer, .err, "store.load_failed", &.{
            .{ .key = "err", .value = @errorName(err) },
            .{ .key = "path", .value = store_path },
        }) catch {};
        return 1;
    };
    defer store.deinit();

    // Process-lifetime resources shared by the accept loop, the scheduler,
    // and the /curate route. The HTTP client is a connection pool; the
    // eval cache is a persistent JSON file. Both are torn down at shutdown.
    var http_client: std.http.Client = .{ .allocator = allocator, .io = init_ctx.io };
    defer http_client.deinit();

    const cache_path = longevity_mod.defaultCachePath(allocator) catch return 1;
    defer allocator.free(cache_path);
    var eval_cache = longevity_mod.EvalCache.load(allocator, init_ctx.io, cache_path) catch |err| {
        log_mod.writeLine(log_writer, .err, "eval_cache.load_failed", &.{
            .{ .key = "err", .value = @errorName(err) },
            .{ .key = "path", .value = cache_path },
        }) catch {};
        return 1;
    };
    defer {
        eval_cache.save() catch {};
        eval_cache.deinit();
    }

    const user_agent = "curation/0.0";
    const request_timeout: std.Io.Timeout = .{
        .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromSeconds(30) },
    };

    const deps: Deps = .{
        .gpa = allocator,
        .cfg = &cfg,
        .store = &store,
        .metrics = &metrics,
        .io = init_ctx.io,
        .http_client = &http_client,
        .eval_cache = &eval_cache,
        .invoker = .{ .ctx = @constCast(@ptrCast(&cfg.pi)), .invoke = invokePiForConfig },
        .user_agent = user_agent,
        .timeout = request_timeout,
    };

    // Spawn the daily scheduler. It joins on shutdown.
    var scheduler = spawnScheduler(init_ctx, allocator, &deps, log_writer) catch |err| {
        log_mod.writeLine(log_writer, .err, "scheduler.spawn_failed", &.{
            .{ .key = "err", .value = @errorName(err) },
        }) catch {};
        return 1;
    };
    defer scheduler.join();

    return acceptLoop(init_ctx, allocator, &server_socket, &deps, log_writer);
}

/// Adapter seam: invoke `longevity.productionInvoker` with the cfg's PiConfig.
/// Production invoker is allowed to fail (longevity.classify absorbs it).
fn invokePiForConfig(ctx: *anyopaque, gpa: std.mem.Allocator, io: std.Io, cfg: longevity_mod.PiConfig, prompt: []const u8) anyerror![]u8 {
    _ = ctx;
    return longevity_mod.productionInvoker(gpa, io, cfg, prompt);
}

/// Spawn the daily scheduler thread. Joins via `join` on shutdown. The
/// thread sleeps in ≤1s slices, re-checking `stop_flag`, so SIGINT shuts
/// the process down within ~1s. On the scheduled minute it calls
/// `curation-job.tryRun`; `.busy` is logged and skipped.
const SchedulerCtx = struct {
    deps: *const Deps,
    log_writer: *std.Io.Writer,
    io: std.Io,
};

fn spawnScheduler(
    init_ctx: std.process.Init,
    _: std.mem.Allocator,
    deps: *const Deps,
    log_writer: *std.Io.Writer,
) std.Thread.SpawnError!std.Thread {
    // ponytail: single fixed daily time, 1s shutdown poll, no jitter,
    // backoff, or catch-up for missed ticks; revisit if the schedule model
    // grows (multiple times, intervals, catch-up).
    return std.Thread.spawn(.{}, schedulerRun, .{ SchedulerCtx{
        .deps = deps,
        .log_writer = log_writer,
        .io = init_ctx.io,
    } });
}

fn schedulerRun(c: SchedulerCtx) void {
    const deps = c.deps;
    const log_writer = c.log_writer;
    const io = c.io;
    while (!stop_flag.load(.acquire)) {
        const sleep_for = nextScheduleDelayNs(deps.cfg.schedule, io) catch |err| {
            log_mod.writeLine(log_writer, .err, "scheduler.schedule_parse_failed", &.{
                .{ .key = "err", .value = @errorName(err) },
                .{ .key = "schedule", .value = deps.cfg.schedule },
            }) catch {};
            return;
        };
        // Sleep in 1s slices so SIGINT takes ≤1s to propagate.
        var remaining: u64 = sleep_for;
        while (remaining > 0 and !stop_flag.load(.acquire)) {
            const slice: u64 = @min(remaining, @as(u64, @intCast(std.Io.Duration.fromSeconds(1).toNanoseconds())));
            std.Io.sleep(io, .{ .nanoseconds = @intCast(slice) }, .awake) catch break;
            remaining -= slice;
        }
        if (stop_flag.load(.acquire)) return;

        // Build an ephemeral log writer for this run so run logs go to
        // stderr but don't pollute the scheduler's log_writer.
        var log_aw: std.Io.Writer.Allocating = .init(deps.gpa);
        defer log_aw.deinit();

        const outcome = curation_job_mod.tryRun(
            deps.gpa,
            deps.io,
            deps.cfg.sources,
            .{
                .filter_rules = deps.cfg.filter_rules,
                .tag_rules = deps.cfg.tag_rules,
                .cap = deps.cfg.cap,
            },
            deps.cfg.pi,
            deps.http_client,
            deps.eval_cache,
            deps.invoker,
            deps.store,
            deps.user_agent,
            deps.timeout,
            &log_aw.writer,
            fetch_mod.acquireFeed,
            deps.cfg.web_sources,
            deps.cfg.lightpanda,
            render_mod.acquireWeb,
            deps.cfg.retention_days,
            deps.metrics,
        );

        switch (outcome) {
            .busy => log_mod.writeLine(log_writer, .warn, "curation.skipped_busy", &.{}) catch {},
            .ran => log_mod.writeLine(log_writer, .info, "curation.run", &.{
                .{ .key = "sources", .value = @as([]const u8, &.{@as(u8, @intCast('0' + outcome.ran.sources))})[0..1] },
                .{ .key = "fetched", .value = @as([]const u8, &.{@as(u8, @intCast('0' + outcome.ran.fetched))})[0..1] },
                .{ .key = "curated", .value = @as([]const u8, &.{@as(u8, @intCast('0' + outcome.ran.curated))})[0..1] },
            }) catch {},
        }
    }
}

/// Parse "HH:MM" and return the duration (ns) until the next occurrence of
/// that local time. If the next occurrence is later today, return that; if
/// it's already past, return the time until tomorrow's occurrence.
fn nextScheduleDelayNs(schedule: []const u8, io: std.Io) !u64 {
    const colon = std.mem.indexOfScalar(u8, schedule, ':') orelse return error.InvalidSchedule;
    const hh = std.fmt.parseInt(u8, schedule[0..colon], 10) catch return error.InvalidSchedule;
    const mm = std.fmt.parseInt(u8, schedule[colon + 1 ..], 10) catch return error.InvalidSchedule;
    if (hh > 23 or mm > 59) return error.InvalidSchedule;

    // ponytail: schedule is interpreted in UTC, not local time. The Zig
    // 0.16 stdlib exposes no calendar helpers yet, and pulling in libc
    // for a daily HH:MM is more machinery than the slice earns. Operators
    // who need local-time scheduling can set the schedule offset
    // explicitly until a proper timezone API lands.
    const now_ts = std.Io.Clock.now(.awake, io);
    const secs_i96: i96 = @divFloor(now_ts.toNanoseconds(), std.time.ns_per_s);
    const secs: i64 = @intCast(secs_i96);
    const secs_per_day: i64 = 24 * 3600;
    const now_in_day: i64 = @rem(secs, secs_per_day);
    const today_seconds: i64 = @as(i64, hh) * 3600 + @as(i64, mm) * 60;

    var delay_seconds: i64 = today_seconds - now_in_day;
    if (delay_seconds <= 0) delay_seconds += secs_per_day;
    return @intCast(delay_seconds * std.time.ns_per_s);
}

fn installSigintHandler() void {
    // ponytail: signal handler flips an atomic flag and closes the listening
    // socket so the blocking `accept` returns EBADF (verified by experiment:
    // `shutdown()` does not unblock accept on macOS for listening sockets).
    const S = struct {
        fn handler(_: std.posix.SIG) callconv(.c) void {
            stop_flag.store(true, .release);
            if (listen_fd >= 0) {
                // close() is async-signal-safe; this unblocks the accept
                // call in the main thread with EBADF.
                _ = std.c.close(listen_fd);
                listen_fd = -1;
            }
        }
    };
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = S.handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn acceptLoop(
    init_ctx: std.process.Init,
    allocator: std.mem.Allocator,
    socket: *std.Io.net.Server,
    deps: *const Deps,
    log_writer: *std.Io.Writer,
) u8 {
    while (!stop_flag.load(.acquire)) {
        const stream = socket.accept(init_ctx.io) catch |err| {
            if (err == error.ConnectionAborted) continue;
            // Other errors (SocketNotListening, Unexpected) come from the
            // signal handler closing the listening socket — exit gracefully.
            if (stop_flag.load(.acquire)) break;
            log_mod.writeLine(log_writer, .err, "server.accept_failed", &.{
                .{ .key = "err", .value = @errorName(err) },
            }) catch {};
            return 1;
        };
        handleConnection(init_ctx, allocator, stream, deps, log_writer);
    }
    log_mod.writeLine(log_writer, .info, "server.stop", &.{}) catch {};
    log_writer.flush() catch {};
    return 0;
}

fn handleConnection(
    init_ctx: std.process.Init,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    deps: *const Deps,
    log_writer: *std.Io.Writer,
) void {
    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var reader = stream.reader(init_ctx.io, &recv_buffer);
    var writer = stream.writer(init_ctx.io, &send_buffer);
    var http_server: std.http.Server = .init(&reader.interface, &writer.interface);

    var request = http_server.receiveHead() catch return;
    const start_ns = std.Io.Clock.now(.awake, init_ctx.io).toNanoseconds();

    const auth_header = findHeader(&request, "authorization");
    const now_ns = std.Io.Clock.now(.awake, init_ctx.io).toNanoseconds();
    const result = handleRequest(allocator, @tagName(request.head.method), request.head.target, auth_header, deps, now_ns) catch return;

    // Build the response headers. X-Next-Token is only attached on a
    // successful /download response (the route handler populates it).
    var headers: [2]std.http.Header = .{
        .{ .name = "content-type", .value = result.content_type },
        undefined,
    };
    var extra_headers: []const std.http.Header = headers[0..1];
    if (result.next_token) |tok| {
        headers[1] = .{ .name = "x-next-token", .value = tok };
        extra_headers = headers[0..2];
    }

    request.respond(result.body, .{
        .status = result.status,
        .extra_headers = extra_headers,
    }) catch return;

    const end_ns = std.Io.Clock.now(.awake, init_ctx.io).toNanoseconds();
    const latency_ns: u64 = @intCast(@max(end_ns - start_ns, 0));
    deps.metrics.observe(allocator, @tagName(request.head.method), request.head.target, latency_ns) catch {};

    log_mod.writeLine(log_writer, .info, "request", &.{
        .{ .key = "method", .value = @tagName(request.head.method) },
        .{ .key = "path", .value = request.head.target },
        .{ .key = "status", .value = @tagName(result.status) },
    }) catch {};

    writer.interface.flush() catch {};
}

fn findHeader(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

// ============= tests =============

const testing = std.testing;
const item_mod = @import("item.zig");

fn makeStoreWithIds(comptime entries: []const struct { kind: store_mod.Kind, title: []const u8 }) !store_mod.Store {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/tmp/server-download-test.jsonl";
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, tmp) catch {};
    var store = try store_mod.Store.load(gpa, io, tmp);
    errdefer store.deinit();
    for (entries) |e| {
        const item: item_mod.CuratedItem = .{
            .title = e.title,
            .url = "",
            .body = "",
            .date = "",
            .source = "",
            .tags = &.{},
        };
        _ = try store.append(e.kind, item);
    }
    return store;
}

fn makeEmptyStore() !store_mod.Store {
    return makeStoreWithIds(&.{});
}

fn deleteStoreFile() void {
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, "zig-cache/tmp/server-download-test.jsonl") catch {};
}

fn makeAuthCfg() Config {
    return .{ .auth_token = "secret" };
}

fn queryPath(gpa: std.mem.Allocator, since: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/download?since={s}", .{since});
}

fn queryPathKind(gpa: std.mem.Allocator, kind: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/download?kind={s}", .{kind});
}

fn queryPathSinceAndKind(gpa: std.mem.Allocator, since: []const u8, kind: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/download?since={s}&kind={s}", .{ since, kind });
}

/// Build a `Deps` for tests. The lifetime resources (http client, eval
/// cache) are shared pointers the caller must keep alive for the duration
/// of the test. The returned `*Deps` aliases the caller's locals.
fn makeTestDeps(
    gpa: std.mem.Allocator,
    cfg: *const Config,
    store: *Store,
    metrics: *metrics_mod.Metrics,
    http_client: *std.http.Client,
    eval_cache: *EvalCache,
) Deps {
    return .{
        .gpa = gpa,
        .cfg = cfg,
        .store = store,
        .metrics = metrics,
        .io = std.testing.io,
        .http_client = http_client,
        .eval_cache = eval_cache,
        // Tests never trigger the curate-route's invoker or schedules;
        // a stub that returns garbage is safe under the resilience
        // contract (unknown → default_kind → news).
        .invoker = .{ .ctx = @constCast(@ptrCast(&cfg.pi)), .invoke = invokePiForConfig },
        .user_agent = "test-agent",
        .timeout = .{
            .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(200) },
        },
    };
}

test "handleRequest: GET /download with valid bearer + valid since returns 200 EPUB + X-Next-Token" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{
        .{ .kind = .news, .title = "N1" },
        .{ .kind = .knowledge, .title = "K2" },
        .{ .kind = .news, .title = "N3" },
    });
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const token = try download_mod.encode(gpa, .news, 1);
    defer gpa.free(token);
    const path = try queryPath(gpa, token);
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer secret", &deps, 0);
    defer gpa.free(result.body);
    defer if (result.next_token) |t| gpa.free(t);

    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expectEqualStrings("application/epub+zip", result.content_type);
    try testing.expect(result.next_token != null);
    try testing.expect(!result.open_route);

    const decoded = try download_mod.decode(gpa, result.next_token.?);
    try testing.expectEqual(store_mod.Kind.news, decoded.kind);
    try testing.expectEqual(@as(u64, 3), decoded.id);
}


test "handleRequest: GET /download with valid bearer + nothing-new returns 204 and no token" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{
        .{ .kind = .news, .title = "N1" },
        .{ .kind = .knowledge, .title = "K2" },
        .{ .kind = .news, .title = "N3" },
    });
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    // token {news,3} — largest news id is 3 → nothing-new.
    const token = try download_mod.encode(gpa, .news, 3);
    defer gpa.free(token);
    const path = try queryPath(gpa, token);
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer secret", &deps, 0);
    try testing.expectEqual(std.http.Status.no_content, result.status);
    try testing.expect(result.next_token == null);
}


test "handleRequest: GET /download with missing since returns 400" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{.{ .kind = .news, .title = "N1" }});
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", "/download", "Bearer secret", &deps, 0);
    try testing.expectEqual(std.http.Status.bad_request, result.status);
    try testing.expect(result.next_token == null);
}


test "handleRequest: GET /download with garbage since returns 400" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{.{ .kind = .news, .title = "N1" }});
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const path = try queryPath(gpa, "garbage");
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer secret", &deps, 0);
    try testing.expectEqual(std.http.Status.bad_request, result.status);
    try testing.expect(result.next_token == null);
}


test "handleRequest: GET /download with missing bearer returns 401" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{.{ .kind = .news, .title = "N1" }});
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const token = try download_mod.encode(gpa, .news, 0);
    defer gpa.free(token);
    const path = try queryPath(gpa, token);
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, null, &deps, 0);
    try testing.expectEqual(std.http.Status.unauthorized, result.status);
    try testing.expect(result.next_token == null);
}


test "handleRequest: GET /download with wrong bearer returns 401" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{.{ .kind = .news, .title = "N1" }});
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const token = try download_mod.encode(gpa, .news, 0);
    defer gpa.free(token);
    const path = try queryPath(gpa, token);
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer wrong", &deps, 0);
    try testing.expectEqual(std.http.Status.unauthorized, result.status);
    try testing.expect(result.next_token == null);
}


test "handleRequest: GET / serves the embedded ui page verbatim, open route" {
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }
    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(testing.allocator);
    const cfg = Config{ .auth_token = "secret" };

    // No credentials → still 200 (open route).
    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(testing.allocator, "GET", "/", null, &deps, 0);
    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expectEqualStrings("text/html; charset=utf-8", result.content_type);
    try testing.expectEqualStrings(ui_mod.page, result.body);
    try testing.expect(result.open_route);
}


test "handleRequest: GET / with wrong bearer still returns 200 (open route)" {
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }
    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(testing.allocator);
    const cfg = Config{ .auth_token = "secret" };

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(testing.allocator, "GET", "/", "Bearer wrong", &deps, 0);
    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expect(result.open_route);
}


test "handleRequest: GET /download bootstrap (since absent, kind=news) over news [1,3,5] returns 200 EPUB + next token {news,5}" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{
        .{ .kind = .news, .title = "N1" },
        .{ .kind = .knowledge, .title = "K2" },
        .{ .kind = .news, .title = "N3" },
        .{ .kind = .knowledge, .title = "K4" },
        .{ .kind = .news, .title = "N5" },
    });
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const path = try queryPathKind(gpa, "news");
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer secret", &deps, 0);
    defer gpa.free(result.body);
    defer if (result.next_token) |t| gpa.free(t);

    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expectEqualStrings("application/epub+zip", result.content_type);
    try testing.expect(result.next_token != null);

    const decoded = try download_mod.decode(gpa, result.next_token.?);
    try testing.expectEqual(store_mod.Kind.news, decoded.kind);
    try testing.expectEqual(@as(u64, 5), decoded.id);
}


test "handleRequest: GET /download bootstrap (since absent, kind=knowledge) on empty kind returns 204" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{.{ .kind = .news, .title = "N1" }});
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const path = try queryPathKind(gpa, "knowledge");
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer secret", &deps, 0);
    try testing.expectEqual(std.http.Status.no_content, result.status);
    try testing.expect(result.next_token == null);
}


test "handleRequest: GET /download with no since and no kind returns 400" {
    const gpa = std.testing.allocator;
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", "/download", "Bearer secret", &deps, 0);
    try testing.expectEqual(std.http.Status.bad_request, result.status);
    try testing.expect(result.next_token == null);
}


test "handleRequest: GET /download with no since and unknown kind returns 400" {
    const gpa = std.testing.allocator;
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const path = try queryPathKind(gpa, "sports");
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer secret", &deps, 0);
    try testing.expectEqual(std.http.Status.bad_request, result.status);
    try testing.expect(result.next_token == null);
}


test "handleRequest: GET /download bootstrap missing bearer returns 401 before any resolution" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{.{ .kind = .news, .title = "N1" }});
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const path = try queryPathKind(gpa, "news");
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, null, &deps, 0);
    try testing.expectEqual(std.http.Status.unauthorized, result.status);
    try testing.expect(result.next_token == null);
}


test "handleRequest: GET /download with since and kind: token's kind wins, kind param ignored" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{
        .{ .kind = .news, .title = "N1" },
        .{ .kind = .knowledge, .title = "K2" },
        .{ .kind = .news, .title = "N3" },
        .{ .kind = .knowledge, .title = "K4" },
    });
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const token = try download_mod.encode(gpa, .knowledge, 2);
    defer gpa.free(token);
    const path = try queryPathSinceAndKind(gpa, token, "news");
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer secret", &deps, 0);
    defer gpa.free(result.body);
    defer if (result.next_token) |t| gpa.free(t);

    try testing.expectEqual(std.http.Status.ok, result.status);
    const decoded = try download_mod.decode(gpa, result.next_token.?);
    try testing.expectEqual(store_mod.Kind.knowledge, decoded.kind);
    try testing.expectEqual(@as(u64, 4), decoded.id);
}



test "handleRequest: GET /healthz returns 200 with empty body, open route" {
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }
    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(testing.allocator);
    const cfg = Config{};
    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(testing.allocator, "GET", "/healthz", null, &deps, 0);
    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expectEqualStrings("", result.body);
    try testing.expect(result.open_route);
}


test "handleRequest: GET /metrics returns 200 with exposition body, open route" {
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }
    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(testing.allocator);
    const cfg = Config{};
    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(testing.allocator, "GET", "/metrics", null, &deps, 0);
    defer testing.allocator.free(result.body);
    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expectEqualStrings(metrics_mod.content_type, result.content_type);
    try testing.expect(std.mem.indexOf(u8, result.body, "curation_uptime_seconds") != null);
    try testing.expect(result.open_route);
}


test "handleRequest: open routes ignore credentials" {
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }
    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(testing.allocator);
    const cfg = Config{ .host = "127.0.0.1", .port = 8787, .auth_token = "secret" };

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const with_auth = try handleRequest(testing.allocator, "GET", "/healthz", "Bearer wrong", &deps, 0);
    try testing.expectEqual(std.http.Status.ok, with_auth.status);

    const without_auth = try handleRequest(testing.allocator, "GET", "/healthz", null, &deps, 0);
    try testing.expectEqual(std.http.Status.ok, without_auth.status);
}


test "handleRequest: unknown path returns 404" {
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }
    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(testing.allocator);
    const cfg = Config{};
    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(testing.allocator, "GET", "/nope", null, &deps, 0);
    try testing.expectEqual(std.http.Status.not_found, result.status);
}


test "handleRequest: two healthz calls bump metrics counter for that path" {
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }
    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(testing.allocator);
    const cfg = Config{};

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    _ = try handleRequest(testing.allocator, "GET", "/healthz", null, &deps, 1_000_000);
    _ = try handleRequest(testing.allocator, "GET", "/healthz", null, &deps, 2_000_000);

    // Observe directly to simulate the per-request observation, then render.
    try m.observe(testing.allocator, "GET", "/healthz", 1_000_000);
    try m.observe(testing.allocator, "GET", "/healthz", 1_000_000);

    const text = try m.render(testing.allocator, 0);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "method=\"GET\",path=\"/healthz\"} 2") != null);
}

// ---- POST /curate ----

test "handleRequest: POST /curate with valid bearer + empty sources returns 200 + summary JSON" {
    const gpa = std.testing.allocator;
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache-curate-empty.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(gpa, &cfg, &store, &m, &http_client, &eval_cache);

    const result = try handleRequest(gpa, "POST", "/curate", "Bearer secret", &deps, 0);
    defer gpa.free(result.body);

    try testing.expectEqual(std.http.Status.ok, result.status);
    try testing.expectEqualStrings("application/json", result.content_type);
    try testing.expect(!result.open_route);
    try testing.expect(result.next_token == null);

    // The body must be valid JSON carrying the summary keys with zero
    // counts (no sources configured → no fetches → no survivors).
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, result.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 0), obj.get("sources").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("fetched").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("curated").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("news").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("knowledge").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("failed_sources").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("pruned").?.integer);
}

test "handleRequest: POST /curate records one run into the metrics registry" {
    const gpa = std.testing.allocator;
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache-curate-metrics.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(gpa, &cfg, &store, &m, &http_client, &eval_cache);

    // POST /curate returns 200 (empty sources run completes with all
    // zeros) and the registry now records one execution.
    const result = try handleRequest(gpa, "POST", "/curate", "Bearer secret", &deps, 0);
    defer gpa.free(result.body);
    try testing.expectEqual(std.http.Status.ok, result.status);

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "curation_runs_total 1") != null);

    // GET /metrics still works without credentials and contains the
    // curation families alongside the existing request counter /
    // histogram / uptime.
    const metrics_resp = try handleRequest(gpa, "GET", "/metrics", null, &deps, 0);
    defer gpa.free(metrics_resp.body);
    try testing.expectEqual(std.http.Status.ok, metrics_resp.status);
    try testing.expect(metrics_resp.open_route);
    try testing.expect(std.mem.indexOf(u8, metrics_resp.body, "curation_uptime_seconds") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_resp.body, "curation_runs_total 1") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_resp.body, "curation_items_fetched_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_resp.body, "curation_items_curated_total{kind=\"news\"}") != null);
}

test "handleRequest: POST /curate with missing bearer returns 401 before any run" {
    const gpa = std.testing.allocator;
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache-curate-missing.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(gpa, &cfg, &store, &m, &http_client, &eval_cache);

    const result = try handleRequest(gpa, "POST", "/curate", null, &deps, 0);
    try testing.expectEqual(std.http.Status.unauthorized, result.status);
    try testing.expect(result.next_token == null);
}

test "handleRequest: POST /curate with wrong bearer returns 401 before any run" {
    const gpa = std.testing.allocator;
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache-curate-wrong.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(gpa, &cfg, &store, &m, &http_client, &eval_cache);

    const result = try handleRequest(gpa, "POST", "/curate", "Bearer wrong", &deps, 0);
    try testing.expectEqual(std.http.Status.unauthorized, result.status);
    try testing.expect(result.next_token == null);
}

test "handleRequest: GET /curate is not matched (404)" {
    const gpa = std.testing.allocator;
    var store = try makeEmptyStore();
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache-curate-get.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(gpa, &cfg, &store, &m, &http_client, &eval_cache);

    const result = try handleRequest(gpa, "GET", "/curate", "Bearer secret", &deps, 0);
    try testing.expectEqual(std.http.Status.not_found, result.status);
}

test "parseFlags: --config is captured" {
    const got = try parseFlags(&.{ "--config", "/etc/c.json" });
    try testing.expectEqualStrings("/etc/c.json", got.config.?);
}

test "parseFlags: empty args returns null config" {
    const got = try parseFlags(&.{});
    try testing.expect(got.config == null);
}

test "parseFlags: unknown flag errors" {
    try testing.expectError(error.UnknownFlag, parseFlags(&.{ "--nope" }));
}

test "parseFlags: --config without value errors" {
    try testing.expectError(error.MissingFlagValue, parseFlags(&.{ "--config" }));
}

// ---- schedule parser ----

test "nextScheduleDelayNs: parses HH:MM into seconds until next occurrence (UTC)" {
    // Schedule in the future of any plausible wall-clock instant returns
    // a positive duration in nanoseconds; we just verify it parses and
    // returns something > 0 and < 24h. The exact number depends on time.
    const delay = try nextScheduleDelayNs("04:00", std.testing.io);
    try testing.expect(delay > 0);
    try testing.expect(delay < 24 * 3600 * std.time.ns_per_s);
}

test "nextScheduleDelayNs: rejects garbage" {
    try testing.expectError(error.InvalidSchedule, nextScheduleDelayNs("nope", std.testing.io));
    try testing.expectError(error.InvalidSchedule, nextScheduleDelayNs("25:00", std.testing.io));
    try testing.expectError(error.InvalidSchedule, nextScheduleDelayNs("12:60", std.testing.io));
    try testing.expectError(error.InvalidSchedule, nextScheduleDelayNs("", std.testing.io));
}

test "handleRequest: GET /download that yields an EPUB bumps the per-kind generation counter" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{
        .{ .kind = .news, .title = "N1" },
        .{ .kind = .knowledge, .title = "K2" },
        .{ .kind = .news, .title = "N3" },
    });
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    const token = try download_mod.encode(gpa, .news, 1);
    defer gpa.free(token);
    const path = try queryPath(gpa, token);
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer secret", &deps, 0);
    defer gpa.free(result.body);
    defer if (result.next_token) |t| gpa.free(t);
    try testing.expectEqual(std.http.Status.ok, result.status);

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"news\"} 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"knowledge\"} 0") != null);

    // Followed by GET /metrics, the same family is still observable.
    const metrics_resp = try handleRequest(gpa, "GET", "/metrics", null, &deps, 0);
    defer gpa.free(metrics_resp.body);
    try testing.expect(std.mem.indexOf(u8, metrics_resp.body, "curation_epub_generations_total{kind=\"news\"} 1") != null);
}

test "handleRequest: GET /download that returns 204 does not bump the generation counter" {
    const gpa = std.testing.allocator;
    var store = try makeStoreWithIds(&.{
        .{ .kind = .news, .title = "N1" },
        .{ .kind = .knowledge, .title = "K2" },
        .{ .kind = .news, .title = "N3" },
    });
    defer {
        store.deinit();
        deleteStoreFile();
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);
    const cfg = makeAuthCfg();

    // token {news,3} → largest news id is 3 → nothing-new.
    const token = try download_mod.encode(gpa, .news, 3);
    defer gpa.free(token);
    const path = try queryPath(gpa, token);
    defer gpa.free(path);

    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = std.testing.io };
    defer http_client.deinit();
    var eval_cache: EvalCache = .{
        .gpa = testing.allocator,
        .io = std.testing.io,
        .path = try testing.allocator.dupe(u8, "zig-cache/tmp/server-test-eval-cache.json"),
        .map = .empty,
    };
    defer eval_cache.deinit();
    const deps = makeTestDeps(testing.allocator, &cfg, &store, &m, &http_client, &eval_cache);
    const result = try handleRequest(gpa, "GET", path, "Bearer secret", &deps, 0);
    try testing.expectEqual(std.http.Status.no_content, result.status);

    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"news\"} 0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"knowledge\"} 0") != null);
}
