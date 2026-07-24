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
const regions = @import("../shell/regions.zig");
const datetime = @import("../platform/datetime.zig");

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
var recent_view: [model.capacity]Notification = undefined;

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

// SEMANTIC classes, never tailwind utilities. app-input.css scans `*.zx` only, deliberately (a
// `*.zig` scan fed it 2174 candidates of ordinary Zig identifiers), so a utility name computed here
// is never generated and the rule silently does not exist. Appearance for these lives in
// app-input.css beside .chat-newmsg-chip, which is Zig-computed state styled the same way.
fn levelClass(comptime base: []const u8, level: Level, comptime tail: []const u8) []const u8 {
    return switch (level) {
        .info => base ++ " " ++ base ++ "-info" ++ tail,
        .success => base ++ " " ++ base ++ "-success" ++ tail,
        .warning => base ++ " " ++ base ++ "-warning" ++ tail,
        .err => base ++ " " ++ base ++ "-err" ++ tail,
    };
}

/// A toast's classes, including the exit state. `is-leaving` goes on for the last sweep of a toast's
/// life, which is what gives the fade-out somewhere to run: the entry leaves the vdom the moment
/// remaining_ms hits zero, so an exit animation has to start BEFORE that, not after it.
pub fn toastClass(n: Notification) []const u8 {
    if (n.remaining_ms <= sweep_ms) return levelClass("st-toast", n.level, " is-leaving");
    return levelClass("st-toast", n.level, "");
}

/// A history row's classes: the same level vocabulary as the toast, with no exit state because the
/// drawer list is not on a timer.
pub fn rowClass(level: Level) []const u8 {
    return levelClass("st-note", level, "");
}

/// History newest first, which is the order the drawer reads in. The store keeps oldest first so
/// eviction is a front removal; this reverses a render's worth into a scratch view rather than
/// paying for a second ordering in the store. Rebuilt per call, so the read flags are never stale.
pub fn recent() []const Notification {
    const h = store.history();
    for (h, 0..) |item, i| recent_view[h.len - 1 - i] = item;
    return recent_view[0..h.len];
}

/// Wall-clock epoch ms off `performance`, NOT `Date.now()`: jsz resolves a property by walking a js
/// VALUE, and a static hanging off a function object does not resolve, so `Date.now()` answers
/// error.InvalidType. `performance` is a plain object, so timeOrigin + now() is the same instant.
/// Same helper home.zig:189 and chat_actions.zig:671 already use.
pub fn nowMs() f64 {
    if (zx.platform.role != .client) return 0;
    const perf = zx.client.js.global.get(zx.client.js.Object, "performance") catch return 0;
    defer perf.deinit();
    const origin = perf.get(f64, "timeOrigin") catch return 0;
    const since = perf.call(f64, "now", .{}) catch return 0;
    return origin + since;
}

/// How long ago a notification arrived, phrased for the drawer. `now_ms` is passed in so one render
/// reads the clock once for the whole list, and the store never reads one at all: it holds the stamp
/// as opaque data, which is what keeps expiry deterministic under test. datetime owns the phrasing.
pub fn ageText(buf: *[32]u8, n: Notification, now_ms: f64) []const u8 {
    return datetime.relativeText(buf, n.created_ms, now_ms);
}

/// Record a notification and show it as a toast. A dropped notification is logged rather than
/// swallowed: losing the message an error would have carried is worse than the allocation failure.
pub fn push(level: Level, text: []const u8, ttl_ms: u32) void {
    _ = store.push(level, text, ttl_ms, nowMs()) catch |err| {
        log.err("notification dropped ({s}): {s}", .{ @errorName(err), text });
        return;
    };
    afterPush();
}

pub fn pushFmt(level: Level, ttl_ms: u32, comptime fmt: []const u8, args: anytype) void {
    _ = store.pushFmt(level, ttl_ms, nowMs(), fmt, args) catch |err| {
        log.err("notification dropped ({s})", .{@errorName(err)});
        return;
    };
    afterPush();
}

/// Opening the drawer is the read receipt. Bumps the Shell (the badge lives on the topbar bell), not
/// the overlay, and only when something actually changes, so a re-open of an already-read list is
/// not a render.
pub fn markAllRead() void {
    if (store.unreadCount() == 0) return;
    store.markAllRead();
    regions.bumpShell();
}

/// The bell badge, capped so a burst cannot widen the topbar. Empty when nothing is unread, which is
/// what the markup keys the badge's presence off.
pub fn badgeText(buf: *[4]u8) []const u8 {
    const n = store.unreadCount();
    if (n == 0) return "";
    if (n > 9) return "9+";
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "9+";
}

/// Empty the history from the drawer's Clear action. Bumps BOTH regions: the overlay because a live
/// toast goes with it, and the Shell because the bell's badge is computed from the same list.
pub fn clear() void {
    store.clear();
    stopSweep();
    regions.bumpNotifications();
    regions.bumpShell();
}

// Two regions, for two different reasons: the overlay gains a toast, and the topbar bell's unread
// badge is computed from the same list. The composer and the chat log are in neither.
fn afterPush() void {
    regions.bumpNotifications();
    regions.bumpShell();
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
