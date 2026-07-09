//! The sanitization boundary between untrusted bytes and `@escaping={.none}`.
//!
//! `SanitizedHtml` carries a witness pointer to a file-private opaque type. Only this file
//! can mint one, and every path through it crosses the door's DOMPurify pass. A caller
//! elsewhere cannot name `Witness`, so it cannot write the struct literal.
//!
//! Proven against the compiler: omitting `witness_token` is `error: missing struct field`,
//! and `.witness_token = .{}` is `error: type '*const Witness' does not support array
//! initialization syntax`. `.witness_token = undefined` DOES compile. Zig has no field
//! privacy, so the type stops accidents, not a determined author. Any bypass is greppable.

const std = @import("std");
const builtin = @import("builtin");

const markdown = @import("markdown");
const quotes = @import("./quotes.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// Rendered server-side in place of message bodies; the client render replaces it.
pub const ssr_placeholder = "ST_SSR_PLACEHOLDER";

extern "env" fn sanitize(ptr: [*]const u8, len: usize) u64;
extern "env" fn sse_start(ptr: [*]const u8, len: usize) void;

const Witness = opaque {};
var witness_anchor: u8 = 0;

fn witness() *const Witness {
    return @ptrCast(&witness_anchor);
}

/// HTML that has crossed the door's DOMPurify pass. The only value `@escaping={.none}` accepts.
pub const SanitizedHtml = struct {
    bytes: []const u8,
    witness_token: *const Witness,

    pub fn unwrap(self: SanitizedHtml) []const u8 {
        return self.bytes;
    }
};

/// The door packs the result as `(ptr << 32) | len`; the buffer is `__zx_alloc`ed and wasm owns it.
fn unpack(packed_result: u64) []u8 {
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(packed_result >> 32)));
    const len: usize = @intCast(packed_result & 0xFFFF_FFFF);
    return ptr[0..len];
}

/// `__zx_alloc` draws from `std.heap.wasm_allocator`, so the door buffer is released once its
/// bytes are copied into the caller's allocator. Without this, streaming leaks one buffer per token.
fn adopt(allocator: std.mem.Allocator, door_buf: []u8) []const u8 {
    defer std.heap.wasm_allocator.free(door_buf);
    return allocator.dupe(u8, door_buf) catch "";
}

pub fn sanitizeHtml(allocator: std.mem.Allocator, raw: []const u8) SanitizedHtml {
    if (comptime !is_wasm) return .{ .bytes = ssr_placeholder, .witness_token = witness() };
    if (raw.len == 0) return .{ .bytes = "", .witness_token = witness() };
    const door_buf = unpack(sanitize(raw.ptr, raw.len));
    return .{ .bytes = adopt(allocator, door_buf), .witness_token = witness() };
}

/// Rendered HTML keyed by a hash of the source body, with the source retained so a hash collision
/// is detected rather than silently serving another message's HTML.
///
/// Entries are never evicted. ziex keeps the previous vtree to diff against, and those vnodes hold
/// these exact pointers, so freeing an entry would dangle. The cache is bounded by the number of
/// distinct message bodies; the streaming tail is not cached at all.
const Entry = struct { src: []const u8, html: []u8 };
var cache: std.HashMapUnmanaged(u64, Entry, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage) = .empty;

/// Quote-wrap, markdown, sanitize. `cacheable` must be false for a body still being streamed.
pub fn renderMessage(allocator: std.mem.Allocator, body: []const u8, cacheable: bool) SanitizedHtml {
    if (comptime !is_wasm) return .{ .bytes = ssr_placeholder, .witness_token = witness() };
    if (body.len == 0) return .{ .bytes = "", .witness_token = witness() };

    const key = std.hash.Wyhash.hash(0, body);
    if (cacheable) {
        if (cache.get(key)) |entry| {
            if (std.mem.eql(u8, entry.src, body)) {
                return .{ .bytes = entry.html, .witness_token = witness() };
            }
        }
    }

    // Degrade rather than lose a message: quote colouring, then markdown, then raw body.
    const quoted = quotes.wrap(allocator, body) catch body;
    const html = markdown.toHtml(allocator, quoted) catch quoted;
    const fresh = sanitizeHtml(allocator, html);
    if (!cacheable) return fresh;

    const owned = std.heap.wasm_allocator.dupe(u8, fresh.bytes) catch return fresh;
    cache.put(std.heap.wasm_allocator, key, .{ .src = body, .html = owned }) catch {
        std.heap.wasm_allocator.free(owned);
        return fresh;
    };
    return .{ .bytes = owned, .witness_token = witness() };
}

/// Asks the door to open an SSE stream. The door calls back into `store.zig` per frame.
pub fn beginSse(url: []const u8) void {
    if (comptime !is_wasm) return;
    sse_start(url.ptr, url.len);
}

fn sseBegin(ptr: [*]const u8, len: usize) callconv(.c) void {
    sse_start(ptr, len);
}

comptime {
    if (is_wasm) @export(&sseBegin, .{ .name = "__st_sse_begin" });
}
