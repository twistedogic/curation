const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    const out = &stdout_file.interface;

    try out.print("curation\n", .{});
    try out.flush();
}

test "smoke" {
    // ponytail: placeholder self-check; replace with real logic tests as the project grows.
    try std.testing.expect(@as(i32, 1) + 1 == 2);
}
