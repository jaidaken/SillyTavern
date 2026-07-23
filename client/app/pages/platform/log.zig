//! Browser log sink: routes std.log through the env.st_log import, which prints the message under
//! its [st:<scope>] prefix. The CATEGORY FILTER lives here, not in the glue: the localStorage
//! st_log spec is read on the first log line and a below-threshold message returns before it is
//! formatted, so it never crosses the wasm boundary. The JS side is a console sink only. Native
//! builds (server render, unit tests) fall back to std.log.defaultLog on stderr.
//!
//! The spec is read HERE rather than being handed in from bridge.bootInit, because this file is
//! compiled TWICE: once as part of the build root (app/main.zig, which points std_options at
//! logFn) and once as the transpiler's copy inside the zx component graph. The two are separate
//! modules with separate globals, so a spec pushed in from a zx module lands on the copy that does
//! not own the sink. Reading it here puts the value in whichever instance is actually logging.

const std = @import("std");
const builtin = @import("builtin");
const zx = @import("zx");
const log_spec = @import("./log_spec.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding;

extern "env" fn st_log(level: u32, scope_ptr: [*]const u8, scope_len: usize, msg_ptr: [*]const u8, msg_len: usize) void;

/// Every category prints info and above until the spec is read.
var thresholds: log_spec.Thresholds = .{};
var spec_read = false;

/// Parse the `st_log` localStorage value ("chars:debug,net:warn") once, on the first log line of
/// the session. A failed read counts as read, so a private-mode browser does not retry per line.
fn ensureSpec() void {
    if (spec_read) return;
    spec_read = true;
    if (comptime !is_wasm) return;
    const ls = zx.client.js.global.get(zx.client.js.Object, "localStorage") catch return;
    defer ls.deinit();
    const raw = ls.callAlloc(?zx.client.js.String, zx.allocator, "getItem", .{zx.client.js.string("st_log")}) catch return;
    const spec = raw orelse return;
    defer zx.allocator.free(spec);
    thresholds = log_spec.parse(spec);
}

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
    const scope_name = @tagName(scope);
    // The filter runs before the format: a silenced debug line costs nothing at all.
    ensureSpec();
    if (!thresholds.enabled(scope_name, message_level)) return;
    const level: u32 = switch (message_level) {
        .err => 0,
        .warn => 1,
        .info => 2,
        .debug => 3,
    };
    // Fixed buffer: log formatting must never allocate; an overlong message truncates.
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(format, args) catch {};
    const msg = w.buffered();
    st_log(level, scope_name.ptr, scope_name.len, msg.ptr, msg.len);
}
