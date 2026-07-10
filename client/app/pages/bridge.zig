//! The door's entry points into the store and the stream.
//!
//! Kept out of `store.zig` and `stream.zig` so both stay pure Zig modules with no `zx` import,
//! which is what lets the native test suite drive them under a safety-checked allocator.
//!
//! Every buffer arriving here was allocated by the door through `__zx_alloc`, which draws from
//! `std.heap.wasm_allocator`, the same allocator the store frees with.
//!
//! These fns are not driven by the native test suite: they call `regions.bumpMessageLog`, which
//! re-renders only the MessageLog region through `zx`, and a native harness would have to supply a
//! wasm-free `zx`. Their door free paths are instead compile-checked by the wasm build, which
//! analyzes them through the `@export` block below.

const std = @import("std");
const builtin = @import("builtin");
const store = @import("./store.zig");
const stream_mod = @import("./stream.zig");
const regions = @import("./regions.zig");
const instrument = @import("./instrument.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

var live: stream_mod.Stream = .{ .allocator = store.page_gpa, .store = &store.global };

/// The door passes a zero address for an empty payload, having allocated nothing for it.
fn doorBuf(addr: usize, len: usize) []u8 {
    if (addr == 0 or len == 0) return &.{};
    return @as([*]u8, @ptrFromInt(addr))[0..len];
}

fn appendMessage(name_ptr: usize, name_len: usize, body_ptr: usize, body_len: usize) callconv(.c) void {
    const name = doorBuf(name_ptr, name_len);
    const body = doorBuf(body_ptr, body_len);
    store.global.append(name, body) catch |err| {
        store.global.allocator.free(name);
        store.global.allocator.free(body);
        std.log.err("append_message: {s}, message dropped", .{@errorName(err)});
        return;
    };
    regions.bumpMessageLog();
}

/// Returns 0 when the stream started, non-zero when `begin` refused it (already streaming) or ran
/// out of memory. The glue honors this instead of flushing tokens into a stream that never opened.
fn streamBegin(name_ptr: usize, name_len: usize) callconv(.c) u32 {
    const name = doorBuf(name_ptr, name_len);
    live.begin(name) catch |err| {
        store.global.allocator.free(name);
        std.log.err("stream_begin: {s}, stream not started", .{@errorName(err)});
        return 1;
    };
    regions.bumpMessageLog();
    return 0;
}

/// Raw SSE bytes, one buffer per animation frame. Decoding and framing happen in `stream.zig`.
///
/// A feed fails only out of memory, and the door has no way to resend the chunk it already freed.
/// Ending the stream seals the tokens that did arrive; returning would strand the message mid
/// stream, refusing every later `begin` and leaving the caret spinning for good.
fn streamAppend(ptr: usize, len: usize) callconv(.c) void {
    const buf = doorBuf(ptr, len);
    defer store.global.allocator.free(buf);
    live.feed(buf) catch |err| {
        std.log.err("stream_append: {s}, stream sealed early", .{@errorName(err)});
        live.end();
    };
    regions.bumpMessageLog();
}

fn streamEnd() callconv(.c) void {
    live.end();
    regions.bumpMessageLog();
}

/// Tokens the Zig framer actually delivered, for the headless harness to assert against.
fn streamTokens() callconv(.c) usize {
    return live.tokens;
}

/// Non-zero once the framer has sealed (a `[DONE]` or an end), so the glue can stop reading a socket
/// the backend may hold open past the sentinel instead of latching its stream state forever.
fn streamDone() callconv(.c) u32 {
    return @intFromBool(live.state == .done);
}

/// Total `MessageView` resolutions so far, for the render-count harness to read per-token deltas.
/// Only compiled and exported when `-Dinstrument` is set, so it never ships in the production wasm.
fn messageViewRenders() callconv(.c) usize {
    return instrument.messageViewRenders();
}

/// Per-region render totals, for the harness to prove scoping: a token must bump only MessageLog, a
/// panel toggle only Shell. Instrument-gated, so they never ship in the production wasm.
fn shellRenders() callconv(.c) usize {
    return instrument.shellRenders();
}

fn messageLogRenders() callconv(.c) usize {
    return instrument.messageLogRenders();
}

fn composerRenders() callconv(.c) usize {
    return instrument.composerRenders();
}

comptime {
    if (is_wasm) {
        @export(&appendMessage, .{ .name = "__st_append_message" });
        @export(&streamBegin, .{ .name = "__st_stream_begin" });
        @export(&streamAppend, .{ .name = "__st_stream_append" });
        @export(&streamEnd, .{ .name = "__st_stream_end" });
        @export(&streamTokens, .{ .name = "__st_stream_tokens" });
        @export(&streamDone, .{ .name = "__st_stream_done" });
        if (instrument.enabled) {
            @export(&messageViewRenders, .{ .name = "__st_mv_renders" });
            @export(&shellRenders, .{ .name = "__st_shell_renders" });
            @export(&messageLogRenders, .{ .name = "__st_messagelog_renders" });
            @export(&composerRenders, .{ .name = "__st_composer_renders" });
        }
    }
}
