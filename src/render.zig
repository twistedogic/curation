// Web-content acquisition: spawn the Lightpanda subprocess, capture stdout
// as the item body.
//
// ponytail: one subprocess per URL, argv-only invocation; revisit a
// persistent lightpanda serve session only if spawn overhead matters.
const std = @import("std");

const config_mod = @import("config.zig");
const item_mod = @import("item.zig");

pub const Item = item_mod.Item;

/// Errors that surface from `acquireWeb` to the caller. The contract is
/// "an error, never a crash" — a missing binary, non-zero exit, timeout,
/// or empty stdout all map to a non-fatal error.
pub const AcquireError = std.process.RunError || std.mem.Allocator.Error || error{
    RenderFailed,
    EmptyOutput,
};

/// Acquire one web-content source by rendering it out-of-process through
/// the Lightpanda headless browser. Invokes
/// `<lightpanda.path> fetch --dump <lightpanda.dump_format> <source.url>`
/// as a child process and captures its stdout as the item body. Returns
/// exactly one `Item` per source on success; reports an error otherwise.
pub fn acquireWeb(
    gpa: std.mem.Allocator,
    io: std.Io,
    source_url: []const u8,
    source_name: []const u8,
    lightpanda: config_mod.LightpandaConfig,
    timeout: std.Io.Timeout,
) AcquireError![]Item {
    const argv = [_][]const u8{
        lightpanda.path,
        "fetch",
        "--dump",
        @tagName(lightpanda.dump_format),
        source_url,
    };

    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .timeout = timeout,
    }) catch |e| return e;

    // run() succeeded: we own stdout and stderr.
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return error.RenderFailed;
        },
        else => {
            gpa.free(result.stdout);
            return error.RenderFailed;
        },
    }

    if (result.stdout.len == 0) {
        gpa.free(result.stdout);
        return error.EmptyOutput;
    }

    // We own everything we put into the item, mirroring the feed parser's
    // memory pattern (title/url/body/date are heap-owned; source is
    // aliased from the caller's source name). `freeAcquired` matches
    // this contract.
    const title = try gpa.dupe(u8, source_name);
    errdefer gpa.free(title);
    const url_field = try gpa.dupe(u8, source_url);
    errdefer gpa.free(url_field);
    const body_alloc = result.stdout;
    errdefer gpa.free(body_alloc);
    const date = try gpa.dupe(u8, "");
    errdefer gpa.free(date);
    const items = try gpa.alloc(Item, 1);
    errdefer gpa.free(items);

    items[0] = .{
        .title = title,
        .url = url_field,
        .body = body_alloc,
        .date = date,
        .source = source_name,
    };
    return items;
}

/// Free a slice returned by `acquireWeb`. Frees every owned field.
pub fn freeAcquired(gpa: std.mem.Allocator, items: []Item) void {
    for (items) |it| {
        gpa.free(it.title);
        gpa.free(it.url);
        gpa.free(it.body);
        gpa.free(it.date);
        // `source` is aliased from the caller; not freed.
    }
    gpa.free(items);
}

// ============= tests =============
//
// The renderer spawns a real subprocess; the test uses a tiny stub
// shell script that interprets its argv to choose behavior, so the
// test is hermetic (no Lightpanda install required) and deterministic.

const STUB_SCRIPT_PATH = "zig-cache/tmp/render-stub-lightpanda.sh";
// argv[4] (url) selects behavior:
//   *contains "fail"*  → exit 1
//   *contains "empty"* → exit 0, no output
//   otherwise          → exit 0, prints "# Hi\n\nbody\n"
const STUB_SCRIPT_CONTENT =
    \\#!/bin/sh
    \\case "$4" in
    \\    *fail*) exit 1 ;;
    \\    *empty*) exit 0 ;;
    \\    *) printf '# Hi\n\nbody\n' ;;
    \\esac
    \\exit 0
;

fn writeStubScript() !void {
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, "zig-cache/tmp");
    {
        const f = try std.Io.Dir.createFile(.cwd(), std.testing.io, STUB_SCRIPT_PATH, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, STUB_SCRIPT_CONTENT);
    }
    // Mark executable so the spawn path can fork+exec it.
    const perm: std.Io.File.Permissions = @enumFromInt(0o755);
    try std.Io.Dir.setFilePermissions(.cwd(), std.testing.io, STUB_SCRIPT_PATH, perm, .{});
}

const test_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromSeconds(5) },
};

test "acquireWeb: successful render yields one item with the captured body" {
    try writeStubScript();
    const gpa = std.testing.allocator;
    const cfg: config_mod.LightpandaConfig = .{ .path = STUB_SCRIPT_PATH };

    const items = try acquireWeb(
        gpa,
        std.testing.io,
        "https://example.com/ok",
        "my-source",
        cfg,
        test_timeout,
    );
    defer freeAcquired(gpa, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("# Hi\n\nbody\n", items[0].body);
    try std.testing.expectEqualStrings("https://example.com/ok", items[0].url);
    try std.testing.expectEqualStrings("my-source", items[0].title);
    try std.testing.expectEqualStrings("my-source", items[0].source);
    try std.testing.expectEqualStrings("", items[0].date);
}

test "acquireWeb: html dump_format is passed verbatim to the child argv" {
    try writeStubScript();
    const gpa = std.testing.allocator;
    // The stub ignores dump_format, but the call should still succeed.
    const cfg: config_mod.LightpandaConfig = .{ .path = STUB_SCRIPT_PATH, .dump_format = .html };

    const items = try acquireWeb(
        gpa,
        std.testing.io,
        "https://example.com/ok",
        "src",
        cfg,
        test_timeout,
    );
    defer freeAcquired(gpa, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
}

test "acquireWeb: missing binary returns an error and no items" {
    const gpa = std.testing.allocator;
    const cfg: config_mod.LightpandaConfig = .{ .path = "/nonexistent/lightpanda-path" };

    if (acquireWeb(
        gpa,
        std.testing.io,
        "https://example.com",
        "src",
        cfg,
        test_timeout,
    )) |items| {
        freeAcquired(gpa, items);
        return error.ShouldHaveFailed;
    } else |_| {
        // Expected: any error.
    }
}

test "acquireWeb: non-zero exit returns error.RenderFailed and no items" {
    try writeStubScript();
    const gpa = std.testing.allocator;
    const cfg: config_mod.LightpandaConfig = .{ .path = STUB_SCRIPT_PATH };

    if (acquireWeb(
        gpa,
        std.testing.io,
        "https://example.com/fail",
        "src",
        cfg,
        test_timeout,
    )) |items| {
        freeAcquired(gpa, items);
        return error.ShouldHaveFailed;
    } else |err| {
        try std.testing.expectEqual(error.RenderFailed, err);
    }
}

test "acquireWeb: empty stdout returns error.EmptyOutput and no items" {
    try writeStubScript();
    const gpa = std.testing.allocator;
    const cfg: config_mod.LightpandaConfig = .{ .path = STUB_SCRIPT_PATH };

    if (acquireWeb(
        gpa,
        std.testing.io,
        "https://example.com/empty",
        "src",
        cfg,
        test_timeout,
    )) |items| {
        freeAcquired(gpa, items);
        return error.ShouldHaveFailed;
    } else |err| {
        try std.testing.expectEqual(error.EmptyOutput, err);
    }
}