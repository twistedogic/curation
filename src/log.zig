// Structured key/value logging (level, event, key=value...).
// ponytail: hand-rolled writer instead of a vendored logger; std.fmt + an
// ArrayList covers the stable field set. Upgrade if field set grows past
// ~20 or schema versioning becomes a concern.
const std = @import("std");

pub const Level = enum { info, warn, err };

pub const Field = struct {
    key: []const u8,
    value: []const u8,
};

/// Writes structured log lines to the given writer.
/// `level` and `event` are emitted first; fields follow in order.
pub fn writeLine(
    writer: *std.Io.Writer,
    level: Level,
    event: []const u8,
    fields: []const Field,
) std.Io.Writer.Error!void {
    try writer.print("level={s} event={s}", .{ @tagName(level), event });
    for (fields) |f| {
        try writer.print(" {s}={s}", .{ f.key, f.value });
    }
    try writer.writeAll("\n");
}

test "log: writes level, event, and key=value fields" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeLine(&aw.writer, .info, "server.start", &.{
        .{ .key = "addr", .value = "127.0.0.1:8787" },
    });

    try std.testing.expectEqualStrings(
        "level=info event=server.start addr=127.0.0.1:8787\n",
        aw.written(),
    );
}

test "log: field order is preserved and key=value space-separated" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeLine(&aw.writer, .info, "req", &.{
        .{ .key = "method", .value = "GET" },
        .{ .key = "path", .value = "/healthz" },
        .{ .key = "status", .value = "200" },
    });

    try std.testing.expectEqualStrings(
        "level=info event=req method=GET path=/healthz status=200\n",
        aw.written(),
    );
}

test "log: warn and err levels serialize as their tag names" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeLine(&aw.writer, .warn, "x", &.{});
    try writeLine(&aw.writer, .err, "y", &.{});

    try std.testing.expectEqualStrings(
        "level=warn event=x\nlevel=err event=y\n",
        aw.written(),
    );
}
