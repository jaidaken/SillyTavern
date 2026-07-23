const std = @import("std");
const zx = @import("zx");

pub fn main(init: zx.Init) !void {
    var app = try zx.App.init(init, zx.io(), zx.allocator, .{}, {});
    defer app.deinit();

    try app.start();
}

// log_level .debug: ReleaseSmall would compile only err logs; the JS logger filters at runtime.
pub const std_options: std.Options = .{
    .logFn = @import("pages/platform/log.zig").logFn,
    .log_level = .debug,
};
pub const panic = std.debug.FullPanic(@import("pages/platform/log.zig").panicHandler);
