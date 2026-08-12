// HTTP feed fetcher: I/O boundary only, no parsing.
// ponytail: std.http.Client wrapper, no retries or backoff; one request per
// call. The `timeout` parameter is part of the public API per design D2; the
// underlying `std.http.Client.fetch` does not expose it directly, so a
// stricter read-timeout becomes a measured-need trigger.
const std = @import("std");

const feed_mod = @import("feed.zig");
pub const Item = feed_mod.Item;

pub const FetchError = std.http.Client.FetchError || std.mem.Allocator.Error || std.Io.Writer.Error || error{
    HttpStatusNotOk,
};

/// Fetch a feed URL via `std.http.Client`. Returns the response body bytes on
/// a 2xx response; returns an error on a non-2xx status, network failure,
/// or allocation failure. The caller owns the returned slice.
pub fn fetchFeed(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    user_agent: []const u8,
    timeout: std.Io.Timeout,
) FetchError![]u8 {
    _ = timeout; // see file-level ponytail note.

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = user_agent },
        },
        .response_writer = &aw.writer,
    });

    if (result.status.class() != .success) return error.HttpStatusNotOk;

    var list = aw.toArrayList();
    return list.toOwnedSlice(gpa);
}

/// Per-source acquisition: fetch + parse for a single source. Returns the
/// extracted items on success, or an error if either fetch or parse fails.
/// One source's failure is reported here so the caller (the daily-job loop)
/// can skip and log it without aborting the run.
pub fn acquireFeed(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    source_url: []const u8,
    source_name: []const u8,
    user_agent: []const u8,
    timeout: std.Io.Timeout,
) (FetchError || std.mem.Allocator.Error)![]Item {
    const bytes = try fetchFeed(gpa, client, source_url, user_agent, timeout);
    defer gpa.free(bytes);
    return feed_mod.parseFeed(gpa, bytes, source_name);
}

// ============= tests =============

test "fetchFeed: unreachable host returns an error without crashing" {
    const gpa = std.testing.allocator;
    var client: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer client.deinit();
    if (fetchFeed(gpa, &client, "http://nonexistent.invalid/feed.xml", "test-agent", .{ .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(200) } })) |_| {
        return error.ShouldHaveFailed;
    } else |_| {
        // Any error is acceptable; the contract is "an error, not a crash".
    }
}

test "acquireFeed: failing source returns an error, not a crash" {
    const gpa = std.testing.allocator;
    var client: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer client.deinit();
    if (acquireFeed(gpa, &client, "http://nonexistent.invalid/feed.xml", "bad-source", "test-agent", .{ .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(200) } })) |items| {
        feed_mod.freeParsed(gpa, items);
        return error.ShouldHaveFailed;
    } else |_| {
        // Expected: any error.
    }
}