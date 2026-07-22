//! The hydrate/reveal stagger, Zig-native. On boot, a double-rAF adds `hydrated` + `revealing` to
//! #chat-root past the first paint (so the stagger settles complete messages, not the empty pre-
//! hydrate frames). `revealing` gates the mes-rise stagger to that first settle: each `.mes` mes-rise
//! animationend (delegated onto #chat via patches 21 + door D6) debounces removing `revealing`, so a
//! later arrival (a prepended history page) rises in at once instead of being delay-hidden.
//!
//! animationend has no clearTimeout in ziex, so the 120ms debounce counts pending timers (the
//! reading_prefs pattern): each mes-rise schedules one, each fires and decrements, and only the last
//! to find none pending clears `revealing` - the same "120ms after the last mes-rise" the glue had.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

// The glue removed `revealing` 120ms after the last mes-rise; keep the interval identical.
const settle_ms: u32 = 120;

var pending: u32 = 0;

fn chatRoot() ?js.Object {
    const doc = js.global.get(js.Object, "document") catch return null;
    defer doc.deinit();
    return doc.call(?js.Object, "querySelector", .{js.string("#chat-root")}) catch null;
}

/// Begin the reveal: past two frames (content-visibility lays out late rows after the first), add
/// `hydrated` + `revealing` to #chat-root. Called from bootInit once the boot render exists.
pub fn startReveal() void {
    if (zx.platform.role != .client) return;
    _ = zx.client.requestAnimationFrame(revealFrame1);
}

fn revealFrame1() void {
    _ = zx.client.requestAnimationFrame(revealFrame2);
}

fn revealFrame2() void {
    const root = chatRoot() orelse return;
    defer root.deinit();
    const cl = root.get(js.Object, "classList") catch return;
    defer cl.deinit();
    cl.call(void, "add", .{ js.string("hydrated"), js.string("revealing") }) catch {};
}

/// A `.mes` mes-rise finished (delegated onto #chat). Debounce clearing `revealing` so it drops
/// 120ms after the LAST mes-rise, not the first.
pub fn onMesRise(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const e = ev.getEvent();
    const name = e.ref.getAlloc(js.String, zx.allocator, "animationName") catch return;
    defer zx.allocator.free(name);
    if (!std.mem.eql(u8, name, "mes-rise")) return;
    pending += 1;
    if (zx.client.setTimeout(revealSettle, settle_ms) == null) {
        // Timer registry full: clear now rather than leave the stagger latched on.
        pending -= 1;
        clearRevealing();
    }
}

fn revealSettle() void {
    if (pending > 0) pending -= 1;
    if (pending != 0) return;
    clearRevealing();
}

fn clearRevealing() void {
    const root = chatRoot() orelse return;
    defer root.deinit();
    const cl = root.get(js.Object, "classList") catch return;
    defer cl.deinit();
    cl.call(void, "remove", .{js.string("revealing")}) catch {};
}
