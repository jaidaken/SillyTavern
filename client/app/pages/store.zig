//! The chat log. Owned here rather than in `ctx.state` because the append path is driven from JS
//! through an exported function that has no `ComponentCtx` in scope. `ChatView` is the only
//! registered client component, so `rerender()` re-renders exactly it and never falls back to
//! `renderAll()` across the page.
//!
//! Every `name` and `body` handed in is owned by the store for the life of the page: they arrive
//! as `__zx_alloc` buffers from the door, or as dupes made here.

const std = @import("std");
const builtin = @import("builtin");
const zx = @import("zx");
const fixtures = @import("./fixtures.zig");

pub const Message = fixtures.Message;

const is_wasm = builtin.target.cpu.arch == .wasm32;
const gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;

var messages: std.ArrayList(Message) = .empty;
var tail: std.ArrayList(u8) = .empty;
var streaming = false;

pub fn slice() []const Message {
    return messages.items;
}

/// Takes ownership of `name` and `body` on success. On failure the caller still owns them.
pub fn append(name: []const u8, body: []const u8) std.mem.Allocator.Error!void {
    try messages.append(gpa, .{ .name = name, .body = body });
}

/// Takes ownership of `name` on success. `tail` is always empty here: `endStream` hands its
/// buffer to the finished message, so a second stream can never overwrite the first one's text.
pub fn beginStream(name: []const u8) std.mem.Allocator.Error!void {
    std.debug.assert(tail.items.len == 0);
    try messages.append(gpa, .{ .name = name, .body = "" });
    streaming = true;
}

/// The tail body grows in place, so it is re-pointed after every append: appendSlice may realloc.
pub fn appendTail(bytes: []const u8) std.mem.Allocator.Error!void {
    if (!streaming or messages.items.len == 0) return;
    try tail.appendSlice(gpa, bytes);
    messages.items[messages.items.len - 1].body = tail.items;
}

/// Seals the tail: the finished message takes the buffer, and `tail` starts over. Without this,
/// the next `beginStream` would reuse the same allocation and rewrite this message's text.
pub fn endStream() void {
    if (!streaming) return;
    streaming = false;
    if (messages.items.len == 0) return;

    const owned = tail.toOwnedSlice(gpa) catch blk: {
        // Shrinking failed; hand over the whole allocation rather than alias it.
        const items = tail.items;
        tail = .empty;
        break :blk items;
    };
    messages.items[messages.items.len - 1].body = owned;
}

/// True only for the message currently receiving tokens. Its body changes every frame, so it must
/// never be cached.
pub fn isStreamingTail(index: usize) bool {
    return streaming and messages.items.len > 0 and index == messages.items.len - 1;
}

fn appendMessage(
    name_ptr: [*]u8,
    name_len: usize,
    body_ptr: [*]u8,
    body_len: usize,
) callconv(.c) void {
    append(name_ptr[0..name_len], body_ptr[0..body_len]) catch {
        gpa.free(name_ptr[0..name_len]);
        gpa.free(body_ptr[0..body_len]);
        return;
    };
    zx.client.rerender();
}

fn streamBegin(name_ptr: [*]const u8, name_len: usize) callconv(.c) void {
    const name = gpa.dupe(u8, name_ptr[0..name_len]) catch return;
    beginStream(name) catch {
        gpa.free(name);
        return;
    };
    zx.client.rerender();
}

/// The door hands over one `__zx_alloc` buffer per animation frame, not per token.
fn streamAppend(ptr: [*]u8, len: usize) callconv(.c) void {
    defer gpa.free(ptr[0..len]);
    appendTail(ptr[0..len]) catch return;
    zx.client.rerender();
}

fn streamEnd() callconv(.c) void {
    endStream();
    zx.client.rerender();
}

comptime {
    if (is_wasm) {
        @export(&appendMessage, .{ .name = "__st_append_message" });
        @export(&streamBegin, .{ .name = "__st_stream_begin" });
        @export(&streamAppend, .{ .name = "__st_stream_append" });
        @export(&streamEnd, .{ .name = "__st_stream_end" });
    }
}
