// curation CLI entry point. See server.zig for subcommand dispatch.
const std = @import("std");

const server = @import("server.zig");

// Pull in test modules so `zig build test` discovers them.
comptime {
    _ = @import("config.zig");
    _ = @import("auth.zig");
    _ = @import("log.zig");
    _ = @import("metrics.zig");
    _ = @import("item.zig");
    _ = @import("curation.zig");
    _ = @import("feed.zig");
    _ = @import("fetch.zig");
    _ = @import("render.zig");
    _ = @import("longevity.zig");
    _ = @import("store.zig");
    _ = @import("download.zig");
    _ = @import("ui.zig");
    _ = @import("curation_job.zig");
    _ = @import("server.zig");
    _ = @import("opml.zig");
}

pub fn main(init_ctx: std.process.Init) u8 {
    const args = init_ctx.minimal.args.toSlice(init_ctx.arena.allocator()) catch return 1;
    return server.run(init_ctx, init_ctx.gpa, args);
}

test "smoke" {
    // ponytail: placeholder self-check; replaced by per-module tests.
    try std.testing.expect(@as(i32, 1) + 1 == 2);
}
