//! Reactive glue over the pure notification_store model: holds the one global Store, drives toast
//! expiry from a single `setInterval`, and re-renders only the Notifications region after each
//! mutation. The model and every pure helper live in notification_store.zig so they are natively
//! testable; this file adds the ziex-facing parts, which client/verify.sh proves in a browser.
//!
//! ONE sweep timer serves every toast. A timer per toast would spend the ziex callback registry (64
//! slots, `.ziex/src/runtime/client/window.zig`) on a burst of notifications, and would need a clock
//! read per toast; instead the sweep hands the store a fixed elapsed_ms and the store does the
//! arithmetic. The timer is cleared once the last toast fades, so an idle app has no periodic wakeup,
//! and the next push starts it again.

const std = @import("std");
const builtin = @import("builtin");
const zx = @import("zx");
const model = @import("./notification_store.zig");
const regions = @import("./regions.zig");

pub const Level = model.Level;
pub const Notification = model.Notification;

const log = std.log.scoped(.notify);

const is_wasm = builtin.target.cpu.arch == .wasm32;
const gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;

/// The sweep cadence, and the elapsed_ms each sweep subtracts.
const sweep_ms: u32 = 250;

/// How long an ordinary toast shows. Errors ask for a longer read, so they pass their own.
pub const default_ttl_ms: u32 = 4000;
pub const error_ttl_ms: u32 = 7000;

var store: model.Store = .{ .allocator = gpa };
var sweep_id: ?u64 = null;

// Read-only views for the render; no bump, so they are safe to call during a render pass.
pub fn toasts() []const Notification {
    return store.toasts();
}
pub fn history() []const Notification {
    return store.history();
}
pub fn unreadCount() usize {
    return store.unreadCount();
}
/// The level as an attribute value, so the level a push carried is readable off the DOM rather than
/// inferred from a colour.
pub fn levelName(level: Level) []const u8 {
    return @tagName(level);
}

// Level rides the left edge in tokens this theme already owns: it has no status ramp, and an
// invented one would put an unowned colour on screen ahead of the overlay's design pass.
const toast_base = "pointer-events-auto rounded-md border border-l-4 border-control-border bg-surface-2 px-3 py-2 text-sm leading-ui text-text";

pub fn toastClass(level: Level) []const u8 {
    return switch (level) {
        .info => toast_base ++ " border-l-border",
        .success => toast_base ++ " border-l-accent",
        .warning => toast_base ++ " border-l-st-quote",
        .err => toast_base ++ " border-l-text",
    };
}

/// Record a notification and show it as a toast. A dropped notification is logged rather than
/// swallowed: losing the message an error would have carried is worse than the allocation failure.
pub fn push(level: Level, text: []const u8, ttl_ms: u32) void {
    _ = store.push(level, text, ttl_ms) catch |err| {
        log.err("notification dropped ({s}): {s}", .{ @errorName(err), text });
        return;
    };
    afterPush();
}

pub fn pushFmt(level: Level, ttl_ms: u32, comptime fmt: []const u8, args: anytype) void {
    _ = store.pushFmt(level, ttl_ms, fmt, args) catch |err| {
        log.err("notification dropped ({s})", .{@errorName(err)});
        return;
    };
    afterPush();
}

pub fn markAllRead() void {
    store.markAllRead();
    regions.bumpNotifications();
}

pub fn clear() void {
    store.clear();
    stopSweep();
    regions.bumpNotifications();
}

fn afterPush() void {
    regions.bumpNotifications();
    startSweep();
}

fn startSweep() void {
    if (sweep_id != null) return;
    if (zx.platform.role != .client) return;
    sweep_id = zx.client.setInterval(sweep, sweep_ms) orelse {
        log.warn("no timer slot for the toast sweep: toasts will stay up until the next push", .{});
        return;
    };
}

fn sweep() void {
    if (store.tick(sweep_ms)) regions.bumpNotifications();
    if (!store.hasToasts()) stopSweep();
}

fn stopSweep() void {
    const id = sweep_id orelse return;
    sweep_id = null;
    zx.client.clearInterval(id);
}
