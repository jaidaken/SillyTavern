//! Focus mode: the immersive reading toggle. While it is on, the edge tabs and the composer fade out
//! so the reading column stands alone; any pointer move or keypress wakes them, and they fade again
//! after a short idle. The message log is never a fade target.
//!
//! The fade itself is CSS, keyed on data-reading-focus="on" and the focus-awake class (opacity only,
//! --move-gated so a reduced-motion reader gets an instant hide/show). This module owns only the
//! activity -> awake -> idle -> asleep state machine. Activity arrives from pointer_track (the door's
//! ambient pointer, once per animation frame) and the composer keydown, both far faster than the idle
//! window, so at most one idle timer is ever outstanding: a new activity re-arms the same slot rather
//! than scheduling a fresh one, because ziex exposes setTimeout but no clearTimeout (the reading_prefs
//! and reveal debounce pattern).

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const log = std.log.scoped(.panels);

/// The chrome fades this long after the last activity. Kobo/Kindle immersive readers hide chrome on
/// an idle beat and reveal it on a tap; here the tap is any pointer move or keypress.
const idle_ms: u32 = 2500;

var enabled: bool = false;
var awake: bool = false;
var timer_armed: bool = false;
var activity_since_arm: bool = false;

fn chatRoot() ?js.Object {
    const doc = js.global.get(js.Object, "document") catch return null;
    defer doc.deinit();
    return doc.call(?js.Object, "querySelector", .{js.string("#chat-root")}) catch null;
}

fn setAwakeClass(on: bool) void {
    const root = chatRoot() orelse return;
    defer root.deinit();
    const cl = root.get(js.Object, "classList") catch return;
    defer cl.deinit();
    cl.call(void, if (on) "add" else "remove", .{js.string("focus-awake")}) catch {};
}

/// Focus mode turned on or off (from the reading pref). On: start awake (the reader is right here at
/// the toggle) and let the first activity arm the idle fade. Off: reset the state; the CSS ignores
/// focus-awake without data-reading-focus="on", so the chrome is fully back regardless.
pub fn setEnabled(on: bool) void {
    if (zx.platform.role != .client) return;
    enabled = on;
    if (on) {
        awake = true;
        setAwakeClass(true);
    } else {
        awake = false;
        activity_since_arm = false;
        setAwakeClass(false);
    }
}

/// A pointer moved or a key was pressed while reading. Wake the chrome if it was asleep and (re)arm
/// the idle timer so it fades again once activity stops. Cheap in the steady state: while already
/// awake with a timer running, this only flips a bool, no DOM work.
pub fn noteActivity() void {
    if (zx.platform.role != .client) return;
    if (!enabled) return;
    if (!awake) {
        awake = true;
        setAwakeClass(true);
    }
    activity_since_arm = true;
    if (!timer_armed) armTimer();
}

fn armTimer() void {
    timer_armed = true;
    activity_since_arm = false;
    if (zx.client.setTimeout(onIdleTick, idle_ms) == null) {
        // Timer registry full: leave the chrome visible rather than latch it hidden.
        timer_armed = false;
    }
}

fn onIdleTick() void {
    timer_armed = false;
    if (activity_since_arm) {
        // Activity landed during the window: chase it with another idle interval rather than hide.
        armTimer();
        return;
    }
    if (awake) {
        awake = false;
        setAwakeClass(false);
        log.debug("focus mode: chrome idle-hidden", .{});
    }
}
