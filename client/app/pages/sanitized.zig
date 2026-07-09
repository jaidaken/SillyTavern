//! The message render pipeline: quote colouring, markdown, then the sanitization boundary.
//!
//! This file never mints a `SanitizedHtml`. It hands raw bytes to `html.sanitizeHtml`, which is the
//! only door to the raw-HTML sink, so no rendering step here can reach `innerHTML` unsanitized.

const std = @import("std");
const builtin = @import("builtin");

const markdown = @import("markdown");
const html = @import("./html.zig");
const quotes = @import("./quotes.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const renderTick = html.renderTick;

extern "env" fn sse_start(ptr: [*]const u8, len: usize) void;

/// Quote-wrap, markdown, sanitize. `cacheable` must be false for a body still being streamed.
pub fn renderMessage(allocator: std.mem.Allocator, body: []const u8, cacheable: bool) html.SanitizedHtml {
    if (comptime !is_wasm) return html.sanitizeHtml(allocator, body);
    if (body.len == 0) return html.sanitizeHtml(allocator, "");

    if (cacheable) {
        if (html.cacheGet(body)) |hit| return hit;
    }

    // Degrade rather than lose a message: quote colouring, then markdown, then the raw body.
    var quoted: []const u8 = body;
    var quoted_owned = false;
    if (quotes.wrap(allocator, body)) |q| {
        quoted = q;
        quoted_owned = true;
    } else |_| {}
    defer if (quoted_owned) allocator.free(quoted);

    var rendered: []const u8 = quoted;
    var rendered_owned = false;
    if (markdown.toHtml(allocator, quoted)) |h| {
        rendered = h;
        rendered_owned = true;
    } else |_| {}
    defer if (rendered_owned) allocator.free(rendered);

    // The sanitized bytes outlive this render, so they never come from the per-render allocator.
    const clean = html.sanitizeHtml(std.heap.wasm_allocator, rendered);
    if (cacheable) html.cachePut(body, clean) else html.retain(clean);
    return clean;
}

/// Asks the door to open an SSE stream. The door calls back into `bridge.zig` per frame.
pub fn beginSse(url: []const u8) void {
    if (comptime !is_wasm) return;
    sse_start(url.ptr, url.len);
}
