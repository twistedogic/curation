// End-to-end daily curation orchestration: fetch → curate → classify → store.
// Composes the existing capabilities; owns the run, the per-source error
// isolation, and the one-at-a-time serialization.
//
// ponytail: one fixed-shape summary, no per-item trace fields; the summary
// is enough for operators and the structured log. ponytail: std.atomic.Mutex
// + tryLock gives non-blocking semantics; only relevant even under
// concurrent POST /curate calls, which is at most two (a cron + a manual).
const std = @import("std");

const config_mod = @import("config.zig");
const curation_mod = @import("curation.zig");
const feed_mod = @import("feed.zig");
const item_mod = @import("item.zig");
const log_mod = @import("log.zig");
const longevity_mod = @import("longevity.zig");
const metrics_mod = @import("metrics.zig");
const store_mod = @import("store.zig");

pub const Source = config_mod.Source;
pub const Rules = config_mod.Rules;
pub const Item = item_mod.Item;
pub const Kind = store_mod.Kind;
pub const Store = store_mod.Store;
pub const PiConfig = longevity_mod.PiConfig;
pub const EvalCache = longevity_mod.EvalCache;
pub const Invoker = longevity_mod.Invoker;

/// One acquisition seam: fetch + parse for one source. Production wires the
/// fetch module's `acquireFeed`; tests inject a stub that returns canned
/// items or errors without touching the network.
pub const AcquireFn = *const fn (
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    source_url: []const u8,
    source_name: []const u8,
    user_agent: []const u8,
    timeout: std.Io.Timeout,
) anyerror![]Item;

/// Parallel seam for web-content sources. The signature differs from
/// `AcquireFn` because Lightpanda does its own HTTP fetching, so the
/// caller supplies a Lightpanda config rather than an HTTP client.
pub const WebAcquireFn = *const fn (
    gpa: std.mem.Allocator,
    io: std.Io,
    source_url: []const u8,
    source_name: []const u8,
    lightpanda: config_mod.LightpandaConfig,
    timeout: std.Io.Timeout,
) anyerror![]Item;

/// Per-run summary. Counts items the run processed end-to-end.
pub const Summary = struct {
    /// Number of sources the run attempted to acquire.
    sources: usize = 0,
    /// Items received across all sources (sum of acquire returns, before
    /// pipeline dedupe/filter/tag/cap).
    fetched: usize = 0,
    /// Items that survived the curation pipeline (after dedupe/filter/tag/cap).
    curated: usize = 0,
    /// Survivors stored under `news`.
    news: usize = 0,
    /// Survivors stored under `knowledge`.
    knowledge: usize = 0,
    /// Sources whose acquire failed (network, status, parse).
    failed_sources: usize = 0,
    /// Number of records removed by the retention prune.
    pruned: usize = 0,
};

/// Outcome of a `tryRun` probe.
pub const RunOutcome = union(enum) {
    /// Run started and completed; carries the summary.
    ran: Summary,
    /// Another run was already in progress; nothing was fetched, classified,
    /// or appended.
    busy,
};

/// Module-level mutex serializing runs. `tryRun` uses `tryLock` so a
/// contended caller never blocks; the scheduler and `POST /curate` both
/// route through this gate.
var run_mutex: std.atomic.Mutex = .unlocked;

/// Synchronous end-to-end run. Composes `fetch` (per-source), `render`
/// (per-web-source), `curation` (pipeline), `longevity` (classify each
/// survivor), and `store` (append). Per-source errors are isolated (logged
/// + counted, run continues). pi failures are absorbed by
/// `longevity.classify`'s fallback and never count as failed sources.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    sources: []const Source,
    rules: Rules,
    pi_cfg: PiConfig,
    client: *std.http.Client,
    cache: *EvalCache,
    invoker: Invoker,
    store: *Store,
    user_agent: []const u8,
    timeout: std.Io.Timeout,
    log_writer: *std.Io.Writer,
    acquire: AcquireFn,
    web_sources: []const Source,
    lightpanda: config_mod.LightpandaConfig,
    web_acquire: WebAcquireFn,
    retention_days: u32,
    metrics: ?*metrics_mod.Metrics,
) anyerror!Summary {
    var summary: Summary = .{};
    summary.sources = sources.len + web_sources.len;

    // Keep each acquire result alive across the pipeline run: the
    // curation pipeline aliases the input `Item` strings onto its
    // `CuratedItem` output, so the underlying byte buffers must outlive
    // the entire `curate → classify → append` chain. We free them in a
    // single defer at function exit.
    //
    // Both feed and web acquire results share the same memory pattern
    // (title/url/body/date heap-owned, `source` aliased), so a single
    // free helper covers both.
    var acquire_results: std.ArrayList([]Item) = .empty;
    defer {
        for (acquire_results.items) |items| feed_mod.freeParsed(gpa, items);
        acquire_results.deinit(gpa);
    }

    var flat_items: std.ArrayList(Item) = .empty;
    defer flat_items.deinit(gpa);

    for (sources) |src| {
        const items = acquire(gpa, client, src.url, src.name, user_agent, timeout) catch |err| {
            summary.failed_sources += 1;
            log_mod.writeLine(log_writer, .warn, "curation.source_failed", &.{
                .{ .key = "source", .value = src.name },
                .{ .key = "err", .value = @errorName(err) },
            }) catch {};
            continue;
        };
        summary.fetched += items.len;
        try acquire_results.append(gpa, items);
        try flat_items.appendSlice(gpa, items);
    }

    for (web_sources) |src| {
        const items = web_acquire(gpa, io, src.url, src.name, lightpanda, timeout) catch |err| {
            summary.failed_sources += 1;
            log_mod.writeLine(log_writer, .warn, "curation.source_failed", &.{
                .{ .key = "source", .value = src.name },
                .{ .key = "err", .value = @errorName(err) },
            }) catch {};
            continue;
        };
        summary.fetched += items.len;
        try acquire_results.append(gpa, items);
        try flat_items.appendSlice(gpa, items);
    }

    // Pure pipeline: dedupe → filter → tag → cap.
    const curated = curation_mod.curate(gpa, flat_items.items, rules) catch |err| {
        log_mod.writeLine(log_writer, .err, "curation.pipeline_failed", &.{
            .{ .key = "err", .value = @errorName(err) },
        }) catch {};
        return summary;
    };
    defer curation_mod.freeCurated(gpa, curated);
    summary.curated = curated.len;

    // Classify each survivor via pi and append under the returned Kind.
    for (curated) |ci| {
        const kind = longevity_mod.classify(gpa, io, ci.title, ci.body, pi_cfg, invoker, cache, log_writer, metrics);
        const id = store.append(kind, ci) catch |err| {
            log_mod.writeLine(log_writer, .err, "curation.append_failed", &.{
                .{ .key = "err", .value = @errorName(err) },
                .{ .key = "kind", .value = @tagName(kind) },
            }) catch {};
            continue;
        };
        _ = id;
        switch (kind) {
            .news => summary.news += 1,
            .knowledge => summary.knowledge += 1,
        }
    }

    if (retention_days > 0) {
        const now = std.Io.Clock.now(.real, io);
        const now_seconds: i64 = @intCast(@divFloor(now.toNanoseconds(), std.time.ns_per_s));
        var count: usize = 0;
        count = store.pruneByAge(now_seconds, @as(i64, retention_days) * std.time.s_per_day) catch |err| blk: {
            log_mod.writeLine(log_writer, .err, "curation.prune_failed", &.{
                .{ .key = "err", .value = @errorName(err) },
            }) catch {};
            break :blk 0;
        };
        summary.pruned = count;
    }

    // Record run summary into the metrics registry if one was provided.
    // `recordCurationRun` is infallible; a null recorder is a no-op (keeps
    // the job's pure-logic unit tests hermetic — design D2).
    if (metrics) |m| m.recordCurationRun(
        @intCast(summary.fetched),
        @intCast(summary.news),
        @intCast(summary.knowledge),
        @intCast(summary.failed_sources),
        @intCast(summary.pruned),
    );

    return summary;
}

/// Non-blocking probe: when no run is in progress, runs one and returns
/// `.ran(summary)`; otherwise returns `.busy` without any side effects.
pub fn tryRun(
    gpa: std.mem.Allocator,
    io: std.Io,
    sources: []const Source,
    rules: Rules,
    pi_cfg: PiConfig,
    client: *std.http.Client,
    cache: *EvalCache,
    invoker: Invoker,
    store: *Store,
    user_agent: []const u8,
    timeout: std.Io.Timeout,
    log_writer: *std.Io.Writer,
    acquire: AcquireFn,
    web_sources: []const Source,
    lightpanda: config_mod.LightpandaConfig,
    web_acquire: WebAcquireFn,
    retention_days: u32,
    metrics: ?*metrics_mod.Metrics,
) RunOutcome {
    if (!run_mutex.tryLock()) return .busy;
    defer run_mutex.unlock();

    const summary = run(gpa, io, sources, rules, pi_cfg, client, cache, invoker, store, user_agent, timeout, log_writer, acquire, web_sources, lightpanda, web_acquire, retention_days, metrics) catch |err| {
        // Run-level errors (OOM) yield a zero summary; the run_mutex is
        // already released by `defer`. A subsequent call starts fresh.
        log_mod.writeLine(log_writer, .err, "curation.run_failed", &.{
            .{ .key = "err", .value = @errorName(err) },
        }) catch {};
        return .{ .ran = Summary{} };
    };
    return .{ .ran = summary };
}

// ============= tests =============
//
// The job's tests inject a stub `AcquireFn` and a stub `Invoker` so no
// network or subprocess is spawned. They open a fresh temp `Store` per
// test (loaded from a temp file) and free it on cleanup.

const TestSource = struct {
    name: []const u8,
    url: []const u8,
    items: []const Item,
};

fn itemFromSlice(gpa: std.mem.Allocator, src: TestSource) ![]Item {
    const out = try gpa.alloc(Item, src.items.len);
    for (src.items, 0..) |it, i| {
        out[i] = .{
            .title = try gpa.dupe(u8, it.title),
            .url = try gpa.dupe(u8, it.url),
            .body = try gpa.dupe(u8, it.body),
            .date = try gpa.dupe(u8, it.date),
            // `source` is aliased — the production `feed.parseFeed` does
            // not own it and `feed.freeParsed` does not free it. The
            // source string outlives the items (the test passes a
            // long-lived source name per acquire call).
            .source = src.name,
        };
    }
    return out;
}

const AcquireCtx = struct {
    /// url → items
    url_to_items: std.StringHashMapUnmanaged([]Item),
    fail_for: ?[]const u8 = null,
};

var test_acquire_ctx: ?*AcquireCtx = null;

fn setupAcquireCtx(gpa: std.mem.Allocator, sources: []const TestSource) !*AcquireCtx {
    const ctx = try gpa.create(AcquireCtx);
    ctx.* = .{ .url_to_items = .empty };
    for (sources) |s| {
        const items = try gpa.alloc(Item, s.items.len);
        for (s.items, 0..) |it, i| {
            items[i] = it;
        }
        try ctx.url_to_items.put(gpa, try gpa.dupe(u8, s.url), items);
    }
    test_acquire_ctx = ctx;
    return ctx;
}

fn teardownAcquireCtx(gpa: std.mem.Allocator, ctx: *AcquireCtx) void {
    // The `Item` string fields are aliased from the test's static test
    // data; only the `[]Item` backing array and the URL key are ours to
    // free. The strings copied out by `itemFromSlice` belong to the
    // acquire result and are freed via `feed_mod.freeParsed` in the run.
    var it = ctx.url_to_items.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.value_ptr.*);
        gpa.free(entry.key_ptr.*);
    }
    ctx.url_to_items.deinit(gpa);
    gpa.destroy(ctx);
    test_acquire_ctx = null;
}

// ---- Stubbed invoker: returns a fresh copy of `payload` per call. ----

const StubPayload = struct {
    payload: []const u8,
};

fn stubInvokeImpl(ctx: *anyopaque, gpa: std.mem.Allocator, _: std.Io, _: PiConfig, _: []const u8) anyerror![]u8 {
    const s: *StubPayload = @ptrCast(@alignCast(ctx));
    return gpa.dupe(u8, s.payload);
}

fn stubInvoker(s: *StubPayload) Invoker {
    return .{ .ctx = @ptrCast(s), .invoke = stubInvokeImpl };
}

// ---- Stubbed acquire: returns canned items keyed by URL via the test ctx,
//      or fails when the URL contains `fail_for`. ----

fn stubAcquire(
    gpa: std.mem.Allocator,
    _: *std.http.Client,
    source_url: []const u8,
    source_name: []const u8,
    _: []const u8,
    _: std.Io.Timeout,
) anyerror![]Item {
    const ctx = test_acquire_ctx.?;
    if (ctx.fail_for) |needle| {
        if (std.mem.indexOf(u8, source_url, needle) != null) return error.HttpStatusNotOk;
    }
    const entry = ctx.url_to_items.get(source_url) orelse return &[_]Item{};
    return itemFromSlice(gpa, .{ .name = source_name, .url = source_url, .items = entry });
}

/// Stubbed web acquire: returns canned items keyed by URL via the same
/// shared acquire context, or fails when the URL contains `fail_for`.
/// The Lightpanda config is ignored — tests don't exercise Lightpanda.
fn stubWebAcquire(
    gpa: std.mem.Allocator,
    _: std.Io,
    source_url: []const u8,
    source_name: []const u8,
    _: config_mod.LightpandaConfig,
    _: std.Io.Timeout,
) anyerror![]Item {
    const ctx = test_acquire_ctx.?;
    if (ctx.fail_for) |needle| {
        if (std.mem.indexOf(u8, source_url, needle) != null) return error.RenderFailed;
    }
    const entry = ctx.url_to_items.get(source_url) orelse return &[_]Item{};
    return itemFromSlice(gpa, .{ .name = source_name, .url = source_url, .items = entry });
}

fn freshStore(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
    try std.Io.Dir.createDirPath(.cwd(), io, "zig-cache/tmp");
    std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    return Store.load(gpa, io, path);
}

fn deleteStorePath(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
}

fn freshCache(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !EvalCache {
    std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    return EvalCache.load(gpa, io, path);
}

fn deleteCachePath(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
}

const test_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(200) },
};

test "run: two sources with three survivors split into kinds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-split.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "a",
            .url = "https://a.example/feed",
            .items = &.{
                .{ .title = "A1", .url = "https://a.example/1", .body = "b1", .date = "", .source = "" },
                .{ .title = "A2", .url = "https://a.example/2", .body = "b2", .date = "", .source = "" },
            },
        },
        .{
            .name = "b",
            .url = "https://b.example/feed",
            .items = &.{
                .{ .title = "B1", .url = "https://b.example/1", .body = "b1", .date = "", .source = "" },
            },
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-split-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub_short: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    // Pass 1: all news (short_term).
    const summary1 = try run(gpa, std.testing.io, &[_]Source{
        .{ .name = "a", .url = "https://a.example/feed" },
        .{ .name = "b", .url = "https://b.example/feed" },
    }, .{}, .{ .default_kind = .news }, &client, &cache, stubInvoker(&stub_short), &store, "test-agent", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 2), summary1.sources);
    try std.testing.expectEqual(@as(usize, 3), summary1.fetched);
    try std.testing.expectEqual(@as(usize, 3), summary1.curated);
    try std.testing.expectEqual(@as(usize, 3), summary1.news);
    try std.testing.expectEqual(@as(usize, 0), summary1.knowledge);
    try std.testing.expectEqual(@as(usize, 0), summary1.failed_sources);

    // Pass 2: a third source with a fresh item, all knowledge (long_term).
    // We replace the ctx's url_to_items in-place rather than tearing down
    // and re-allocating, so the deferred teardown runs exactly once.
    {
        if (acq.url_to_items.fetchRemove("https://a.example/feed")) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
        if (acq.url_to_items.fetchRemove("https://b.example/feed")) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
        const new_items = try gpa.alloc(Item, 1);
        new_items[0] = .{ .title = "C1", .url = "https://c.example/1", .body = "c1b", .date = "", .source = "" };
        try acq.url_to_items.put(gpa, try gpa.dupe(u8, "https://c.example/feed"), new_items);
    }

    var stub_long: StubPayload = .{ .payload = "long_term" };
    const summary2 = try run(gpa, std.testing.io, &[_]Source{
        .{ .name = "c", .url = "https://c.example/feed" },
    }, .{}, .{ .default_kind = .knowledge }, &client, &cache, stubInvoker(&stub_long), &store, "test-agent", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 1), summary2.sources);
    try std.testing.expectEqual(@as(usize, 1), summary2.fetched);
    try std.testing.expectEqual(@as(usize, 1), summary2.curated);
    try std.testing.expectEqual(@as(usize, 0), summary2.news);
    try std.testing.expectEqual(@as(usize, 1), summary2.knowledge);

    // Store has 4 records: 3 news + 1 knowledge.
    const news_recs = try store.range(.news, 0);
    defer gpa.free(news_recs);
    try std.testing.expectEqual(@as(usize, 3), news_recs.len);
    const know_recs = try store.range(.knowledge, 0);
    defer gpa.free(know_recs);
    try std.testing.expectEqual(@as(usize, 1), know_recs.len);
}

test "run: cap of 2 over five survivors stores at most two" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-cap.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "x",
            .url = "https://x.example/feed",
            .items = &.{
                .{ .title = "A1", .url = "https://x.example/1", .body = "b", .date = "", .source = "" },
                .{ .title = "A2", .url = "https://x.example/2", .body = "b", .date = "", .source = "" },
                .{ .title = "A3", .url = "https://x.example/3", .body = "b", .date = "", .source = "" },
                .{ .title = "A4", .url = "https://x.example/4", .body = "b", .date = "", .source = "" },
                .{ .title = "A5", .url = "https://x.example/5", .body = "b", .date = "", .source = "" },
            },
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-cap-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(gpa, std.testing.io, &[_]Source{
        .{ .name = "x", .url = "https://x.example/feed" },
    }, .{ .cap = 2 }, .{ .default_kind = .news }, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 5), summary.fetched);
    try std.testing.expectEqual(@as(usize, 2), summary.curated);
    try std.testing.expectEqual(@as(usize, 2), summary.news);

    const recs = try store.range(.news, 0);
    defer gpa.free(recs);
    try std.testing.expectEqual(@as(usize, 2), recs.len);
}

test "run: failing source increments failed_sources and the run continues" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-fail.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "good",
            .url = "https://good.example/feed",
            .items = &.{
                .{ .title = "G1", .url = "https://good.example/1", .body = "b", .date = "", .source = "" },
            },
        },
        .{
            .name = "bad",
            .url = "https://bad.example/feed",
            .items = &.{},
        },
        .{
            .name = "good2",
            .url = "https://good2.example/feed",
            .items = &.{
                .{ .title = "G2", .url = "https://good2.example/1", .body = "b", .date = "", .source = "" },
            },
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    acq.fail_for = "bad";
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-fail-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(gpa, std.testing.io, &[_]Source{
        .{ .name = "good", .url = "https://good.example/feed" },
        .{ .name = "bad", .url = "https://bad.example/feed" },
        .{ .name = "good2", .url = "https://good2.example/feed" },
    }, .{}, .{}, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 3), summary.sources);
    try std.testing.expectEqual(@as(usize, 1), summary.failed_sources);
    try std.testing.expectEqual(@as(usize, 2), summary.fetched);
    try std.testing.expectEqual(@as(usize, 2), summary.curated);
    try std.testing.expectEqual(@as(usize, 2), summary.news);

    const recs = try store.range(.news, 0);
    defer gpa.free(recs);
    try std.testing.expectEqual(@as(usize, 2), recs.len);

    // Failure was logged at WARN level.
    try std.testing.expect(std.mem.indexOf(u8, log_aw.written(), "level=warn") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_aw.written(), "curation.source_failed") != null);
}

test "run: pi failure stores the survivor under the fallback kind, not failed_sources" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-pi-fail.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "x",
            .url = "https://x.example/feed",
            .items = &.{
                .{ .title = "A1", .url = "https://x.example/1", .body = "b", .date = "", .source = "" },
            },
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-pi-fail-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    // Stub invoker returns garbage → unknown → default_kind (news).
    var stub: StubPayload = .{ .payload = "I have no idea" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(gpa, std.testing.io, &[_]Source{
        .{ .name = "x", .url = "https://x.example/feed" },
    }, .{}, .{ .default_kind = .news }, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 0), summary.failed_sources);
    try std.testing.expectEqual(@as(usize, 1), summary.curated);
    try std.testing.expectEqual(@as(usize, 1), summary.news);

    const recs = try store.range(.news, 0);
    defer gpa.free(recs);
    try std.testing.expectEqual(@as(usize, 1), recs.len);
}

test "run: one feed source + one web source store two survivors under knowledge and sources == 2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-mixed.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    // The shared acquire ctx drives both feed and web stubs by URL;
    // the run iterates feed sources first then web sources and folds
    // both into the same `flat_items` union.
    const sources = [_]TestSource{
        .{
            .name = "feed-src",
            .url = "https://f.example/feed",
            .items = &.{
                .{ .title = "F1", .url = "https://f.example/1", .body = "fb", .date = "", .source = "" },
            },
        },
        .{
            .name = "web-src",
            .url = "https://w.example/page",
            .items = &.{
                .{ .title = "W1", .url = "https://w.example/1", .body = "wb", .date = "", .source = "" },
            },
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-mixed-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub: StubPayload = .{ .payload = "long_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(gpa, std.testing.io, &[_]Source{
        .{ .name = "feed-src", .url = "https://f.example/feed" },
    }, .{}, .{ .default_kind = .knowledge }, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &[_]Source{
        .{ .name = "web-src", .url = "https://w.example/page" },
    }, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 2), summary.sources);
    try std.testing.expectEqual(@as(usize, 2), summary.fetched);
    try std.testing.expectEqual(@as(usize, 2), summary.curated);
    try std.testing.expectEqual(@as(usize, 2), summary.knowledge);
    try std.testing.expectEqual(@as(usize, 0), summary.failed_sources);

    const recs = try store.range(.knowledge, 0);
    defer gpa.free(recs);
    try std.testing.expectEqual(@as(usize, 2), recs.len);
}

test "run: failing web source increments failed_sources and the run still stores the feed source's survivor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-web-fail.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "feed-src",
            .url = "https://f.example/feed",
            .items = &.{
                .{ .title = "F1", .url = "https://f.example/1", .body = "fb", .date = "", .source = "" },
            },
        },
        .{
            .name = "web-src",
            .url = "https://w.example/page",
            .items = &.{}, // stub will fail anyway via fail_for
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    acq.fail_for = "w.example"; // web acquire fails for this URL
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-web-fail-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub: StubPayload = .{ .payload = "long_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(gpa, std.testing.io, &[_]Source{
        .{ .name = "feed-src", .url = "https://f.example/feed" },
    }, .{}, .{ .default_kind = .knowledge }, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &[_]Source{
        .{ .name = "web-src", .url = "https://w.example/page" },
    }, .{}, stubWebAcquire, 0, null);
    // 2 sources attempted, 1 succeeded (feed), 1 failed (web).
    try std.testing.expectEqual(@as(usize, 2), summary.sources);
    try std.testing.expectEqual(@as(usize, 1), summary.failed_sources);
    try std.testing.expectEqual(@as(usize, 1), summary.fetched);
    try std.testing.expectEqual(@as(usize, 1), summary.curated);
    try std.testing.expectEqual(@as(usize, 1), summary.knowledge);

    // Feed survivor stored; web failure did not abort the run.
    const recs = try store.range(.knowledge, 0);
    defer gpa.free(recs);
    try std.testing.expectEqual(@as(usize, 1), recs.len);

    // The web failure was logged.
    try std.testing.expect(std.mem.indexOf(u8, log_aw.written(), "level=warn") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_aw.written(), "curation.source_failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_aw.written(), "web-src") != null);
}

test "run: empty source list fetches nothing and stores nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-empty.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const cache_path = "zig-cache/tmp/curation-job-empty-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(gpa, std.testing.io, &.{}, .{}, .{}, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 0), summary.sources);
    try std.testing.expectEqual(@as(usize, 0), summary.fetched);
    try std.testing.expectEqual(@as(usize, 0), summary.curated);
    try std.testing.expectEqual(@as(usize, 0), summary.news);
    try std.testing.expectEqual(@as(usize, 0), summary.knowledge);
    try std.testing.expectEqual(@as(usize, 0), summary.failed_sources);
}

test "run: retention prunes old records and reports the count" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-retention.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    _ = try store.append(.news, .{
        .title = "old",
        .url = "https://example.test/old",
        .body = "body",
        .date = "2000-01-01T00:00:00Z",
        .source = "test",
        .tags = &.{},
    });

    const cache_path = "zig-cache/tmp/curation-job-retention-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(gpa, io, &.{}, .{}, .{}, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 90, null);
    try std.testing.expectEqual(@as(usize, 1), summary.pruned);
    const records = try store.range(.news, 0);
    defer gpa.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "run: zero retention leaves old records and reports zero" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-retention-zero.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    _ = try store.append(.news, .{
        .title = "old",
        .url = "https://example.test/old",
        .body = "body",
        .date = "2000-01-01T00:00:00Z",
        .source = "test",
        .tags = &.{},
    });

    const cache_path = "zig-cache/tmp/curation-job-retention-zero-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(gpa, io, &.{}, .{}, .{}, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 0), summary.pruned);
    const records = try store.range(.news, 0);
    defer gpa.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
}

test "tryRun: returns busy when the mutex is already held, appends nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-busy.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    // Acquire the module mutex manually: tryRun should observe it.
    if (!run_mutex.tryLock()) return error.ExpectedLockAvailable;
    defer run_mutex.unlock();

    const cache_path = "zig-cache/tmp/curation-job-busy-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const outcome = tryRun(gpa, std.testing.io, &.{}, .{}, .{}, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(RunOutcome{ .busy = {} }, outcome);

    // The store is untouched: range returns empty.
    const recs = try store.range(.news, 0);
    defer gpa.free(recs);
    try std.testing.expectEqual(@as(usize, 0), recs.len);
}

test "run: with a metrics recorder, records the summary into the counters and renders them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-metrics.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "a",
            .url = "https://a.example/feed",
            .items = &.{
                .{ .title = "A1", .url = "https://a.example/1", .body = "b", .date = "", .source = "" },
                .{ .title = "A2", .url = "https://a.example/2", .body = "b", .date = "", .source = "" },
                .{ .title = "A3", .url = "https://a.example/3", .body = "b", .date = "", .source = "" },
            },
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-metrics-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    var stub_short: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    // Run once: 3 items fetched, all classified as news. The recorder
    // observes one run, three fetched, three news, zero knowledge,
    // zero errors, zero pruned.
    const summary = try run(gpa, std.testing.io, &[_]Source{
        .{ .name = "a", .url = "https://a.example/feed" },
    }, .{}, .{ .default_kind = .news }, &client, &cache, stubInvoker(&stub_short), &store, "test-agent", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, &m);
    try std.testing.expectEqual(@as(usize, 3), summary.fetched);
    try std.testing.expectEqual(@as(usize, 3), summary.news);
    try std.testing.expectEqual(@as(usize, 0), summary.knowledge);

    {
        const text = try m.render(gpa, 0);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "curation_runs_total 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_fetched_total 3") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_curated_total{kind=\"news\"} 3") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_curated_total{kind=\"knowledge\"} 0") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "curation_source_fetch_errors_total 0") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_pruned_total 0") != null);
    }
}

test "run: a second run that fails one source and prunes two records bumps those counters" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-metrics-fail.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "good",
            .url = "https://good.example/feed",
            .items = &.{
                .{ .title = "G1", .url = "https://good.example/1", .body = "b", .date = "", .source = "" },
            },
        },
        .{
            .name = "bad",
            .url = "https://bad.example/feed",
            .items = &.{},
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    acq.fail_for = "bad.example";
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-metrics-fail-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    var stub: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    // Seed two old records so the prune removes them.
    _ = try store.append(.news, .{
        .title = "old1",
        .url = "https://example.test/old1",
        .body = "b",
        .date = "2000-01-01T00:00:00Z",
        .source = "test",
        .tags = &.{},
    });
    _ = try store.append(.news, .{
        .title = "old2",
        .url = "https://example.test/old2",
        .body = "b",
        .date = "2000-01-02T00:00:00Z",
        .source = "test",
        .tags = &.{},
    });

    const summary = try run(gpa, std.testing.io, &[_]Source{
        .{ .name = "good", .url = "https://good.example/feed" },
        .{ .name = "bad", .url = "https://bad.example/feed" },
    }, .{}, .{ .default_kind = .news }, &client, &cache, stubInvoker(&stub), &store, "test-agent", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 90, &m);
    try std.testing.expectEqual(@as(usize, 1), summary.failed_sources);
    try std.testing.expectEqual(@as(usize, 2), summary.pruned);

    {
        const text = try m.render(gpa, 0);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "curation_runs_total 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "curation_source_fetch_errors_total 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_pruned_total 2") != null);
    }
}

test "tryRun: a busy probe records nothing in the metrics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-busy-metrics.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const cache_path = "zig-cache/tmp/curation-job-busy-metrics-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    // Hold the run mutex so tryRun observes .busy.
    if (!run_mutex.tryLock()) return error.ExpectedLockAvailable;
    defer run_mutex.unlock();

    var stub: StubPayload = .{ .payload = "short_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const outcome = tryRun(gpa, std.testing.io, &.{}, .{}, .{}, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, &m);
    try std.testing.expectEqual(RunOutcome{ .busy = {} }, outcome);

    // Busy probe did not record anything.
    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_runs_total 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_fetched_total 0") != null);
}



test "tryRun: returns ran with a fresh summary after a previous run completes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-tryrun.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "a",
            .url = "https://a.example/feed",
            .items = &.{
                .{ .title = "A1", .url = "https://a.example/1", .body = "b", .date = "", .source = "" },
            },
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-tryrun-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var stub: StubPayload = .{ .payload = "long_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const outcome1 = tryRun(gpa, std.testing.io, &[_]Source{
        .{ .name = "a", .url = "https://a.example/feed" },
    }, .{}, .{ .default_kind = .knowledge }, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 1), outcome1.ran.news + outcome1.ran.knowledge);
    try std.testing.expectEqual(@as(usize, 1), outcome1.ran.knowledge);

    // Second call runs again, fresh.
    const outcome2 = tryRun(gpa, std.testing.io, &[_]Source{
        .{ .name = "a", .url = "https://a.example/feed" },
    }, .{}, .{ .default_kind = .knowledge }, &client, &cache, stubInvoker(&stub), &store, "ua", test_timeout, &log_aw.writer, stubAcquire, &.{}, .{}, stubWebAcquire, 0, null);
    try std.testing.expectEqual(@as(usize, 1), outcome2.ran.knowledge);

    // Two records stored (cached, so no new invoker calls).
    const recs = try store.range(.knowledge, 0);
    defer gpa.free(recs);
    try std.testing.expectEqual(@as(usize, 2), recs.len);
}

test "run: a cache-miss pi invocation increments the pi-evaluation totals" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-pi-eval.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "x",
            .url = "https://x.example/feed",
            .items = &.{
                .{ .title = "X1", .url = "https://x.example/1", .body = "b", .date = "", .source = "" },
            },
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-pi-eval-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    var stub: StubPayload = .{ .payload = "long_term" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(
        gpa,
        std.testing.io,
        &[_]Source{.{ .name = "x", .url = "https://x.example/feed" }},
        .{},
        .{ .default_kind = .knowledge },
        &client,
        &cache,
        stubInvoker(&stub),
        &store,
        "ua",
        test_timeout,
        &log_aw.writer,
        stubAcquire,
        &.{},
        .{},
        stubWebAcquire,
        0,
        &m,
    );
    _ = summary;
    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_failed_total 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluation_duration_seconds_count 1") != null);
    // Existing run-summary counters still present.
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_runs_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_curated_total{kind=\"knowledge\"} 1") != null);
}

test "run: a pi failure increments the failed-evaluations counter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const store_path = "zig-cache/tmp/curation-job-pi-fail-eval.jsonl";
    var store = try freshStore(gpa, io, store_path);
    defer {
        store.deinit();
        deleteStorePath(io, store_path);
    }

    const sources = [_]TestSource{
        .{
            .name = "x",
            .url = "https://x.example/feed",
            .items = &.{
                .{ .title = "X1", .url = "https://x.example/1", .body = "b", .date = "", .source = "" },
            },
        },
    };
    const acq = try setupAcquireCtx(gpa, &sources);
    defer teardownAcquireCtx(gpa, acq);

    const cache_path = "zig-cache/tmp/curation-job-pi-fail-eval-cache.json";
    var cache = try freshCache(gpa, io, cache_path);
    defer {
        cache.deinit();
        deleteCachePath(io, cache_path);
    }

    var m = metrics_mod.Metrics.init(0);
    defer m.deinit(gpa);

    // Garbage payload → unknown → default_kind (news) → failure.
    var stub: StubPayload = .{ .payload = "I have no idea" };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var log_aw: std.Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    const summary = try run(
        gpa,
        std.testing.io,
        &[_]Source{.{ .name = "x", .url = "https://x.example/feed" }},
        .{},
        .{ .default_kind = .news },
        &client,
        &cache,
        stubInvoker(&stub),
        &store,
        "ua",
        test_timeout,
        &log_aw.writer,
        stubAcquire,
        &.{},
        .{},
        stubWebAcquire,
        0,
        &m,
    );
    _ = summary;
    const text = try m.render(gpa, 0);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_failed_total 1") != null);
    // Run-summary still recorded.
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_runs_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_curated_total{kind=\"news\"} 1") != null);
}
