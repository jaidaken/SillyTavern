//! Browser log sink: routes std.log through the env.st_log import so the JS logger in
//! glue/custom.js applies the [st:<scope>] prefix and the localStorage st_log category filter.
//! Native builds (server render, unit tests) fall back to std.log.defaultLog on stderr.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding;

extern "env" fn st_log(level: u32, scope_ptr: [*]const u8, scope_len: usize, msg_ptr: [*]const u8, msg_len: usize) void;

/// Panic messages reach the browser console via st_log before the trap; without this a wasm
/// panic surfaces as a bare 'RuntimeError: unreachable' with no message.
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (comptime is_wasm) {
        st_log(0, "panic", 5, msg.ptr, msg.len);
        @trap();
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !is_wasm) {
        std.log.defaultLog(message_level, scope, format, args);
        return;
    }
    const level: u32 = switch (message_level) {
        .err => 0,
        .warn => 1,
        .info => 2,
        .debug => 3,
    };
    const scope_name = @tagName(scope);
    // Fixed buffer: log formatting must never allocate; an overlong message truncates.
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(format, args) catch {};
    const msg = w.buffered();
    st_log(level, scope_name.ptr, scope_name.len, msg.ptr, msg.len);
}
