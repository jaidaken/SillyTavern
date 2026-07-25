//! The exit-animation state machine shared by every toggled overlay (the side panels, the styled
//! dropdown, the message-action menu, the undo surfaces, the system card, the notify popover, the
//! command palette).
//!
//! WHY THIS EXISTS. An overlay is CONDITIONALLY RENDERED: `{if (open) (...)}`. The moment its state
//! flips to closed the element leaves the vdom and the DOM node is removed the same frame, so there
//! is nothing left on screen to animate out. To animate a close, the element has to stay mounted
//! through the exit animation and unmount only after it finishes. This three-phase machine is that
//! linger: `closed` (unmounted), `open` (mounted, entry animation), `closing` (still mounted, exit
//! animation running). The render keys its `{if}` off `isMounted()` (open OR closing) and its class
//! off `isClosing()`.
//!
//! THE TIMER, AND WHY THE GUARD. ziex exposes `setTimeout` but NOT `clearTimeout` (only intervals
//! clear; see `.ziex/src/runtime/client/window.zig`). So a pending close timer can never be
//! cancelled once armed. Instead the timer callback is made idempotent: `requestClose` flips
//! open->closing and the driver arms a `setTimeout`; when it fires it calls `timerFired`, which
//! unmounts ONLY if the phase is still `closing`. A re-open in the meantime calls `open`, which
//! forces the phase back to `open`, so the stale timer's `timerFired` is a no-op. That is what makes
//! re-open-during-exit safe: exactly one node stays mounted throughout (its class flips entry<->exit),
//! never a second instance and never a zombie left behind.
//!
//! Pure Zig (no ziex): the driver modules own the `setTimeout` and the re-render; this owns only the
//! phase transitions, so it is proven in the native `zig build test` aggregator.

const std = @import("std");

pub const Phase = enum { closed, open, closing };

/// One overlay's open/exit phase. A driver embeds this, calls `open`/`requestClose`/`timerFired`,
/// and reads `isMounted`/`isClosing`/`isOpen` from the render.
pub const Exit = struct {
    phase: Phase = .closed,

    /// Fully open: the entry animation plays and interactive controls (aria-expanded, the accent
    /// face) read as open. False while the exit animation is running.
    pub fn isOpen(self: Exit) bool {
        return self.phase == .open;
    }

    /// The exit animation is running: the element is still mounted but on its way out, so the render
    /// gives it the exit-animation class and drops its pointer events.
    pub fn isClosing(self: Exit) bool {
        return self.phase == .closing;
    }

    /// Keep rendering the element: it is open, or it is lingering through its exit animation. This is
    /// what the `{if}` gate reads, so a close animation has a node to run on.
    pub fn isMounted(self: Exit) bool {
        return self.phase != .closed;
    }

    /// Open (or re-open). Forces the phase to `open`, which also CANCELS an in-progress close: a
    /// timer armed by the earlier `requestClose` will find the phase no longer `closing` and do
    /// nothing. Idempotent when already open.
    pub fn open(self: *Exit) void {
        self.phase = .open;
    }

    /// Begin closing. Returns true when an exit animation should run (the overlay was open, so the
    /// caller arms the timer); false when there was nothing open to animate, so the caller skips the
    /// timer and the state is left untouched.
    pub fn requestClose(self: *Exit) bool {
        if (self.phase != .open) return false;
        self.phase = .closing;
        return true;
    }

    /// The armed close timer fired. Unmount ONLY if still closing; a re-open (or a hard close) since
    /// the timer was armed leaves the phase elsewhere and this is a no-op. Returns true when it
    /// committed the unmount, which the driver reads as "re-render to drop the element".
    pub fn timerFired(self: *Exit) bool {
        if (self.phase == .closing) {
            self.phase = .closed;
            return true;
        }
        return false;
    }

    /// Close with no animation at all: the reduced-motion / instant path, and the hard close a
    /// resync or a data mutation needs (the element is being replaced, not dismissed). Leaves the
    /// phase `closed` so any pending timer is a no-op.
    pub fn closeInstant(self: *Exit) void {
        self.phase = .closed;
    }
};

const t = std.testing;

test "a fresh exit is closed and unmounted" {
    const e: Exit = .{};
    try t.expect(!e.isOpen());
    try t.expect(!e.isClosing());
    try t.expect(!e.isMounted());
}

test "open then requestClose walks closed -> open -> closing -> closed" {
    var e: Exit = .{};
    e.open();
    try t.expect(e.isOpen());
    try t.expect(e.isMounted());
    try t.expect(!e.isClosing());

    try t.expect(e.requestClose());
    try t.expect(!e.isOpen());
    try t.expect(e.isClosing());
    try t.expect(e.isMounted()); // still on screen for the exit animation

    try t.expect(e.timerFired());
    try t.expect(!e.isMounted());
    try t.expect(e.phase == .closed);
}

test "requestClose on a closed overlay does nothing and arms no timer" {
    var e: Exit = .{};
    try t.expect(!e.requestClose());
    try t.expect(!e.isMounted());
    // Already closing: a second requestClose does not re-arm.
    e.open();
    try t.expect(e.requestClose());
    try t.expect(!e.requestClose());
    try t.expect(e.isClosing());
}

test "re-open during the exit animation makes the stale timer a no-op" {
    var e: Exit = .{};
    e.open();
    try t.expect(e.requestClose()); // timer armed here
    // The user re-opens before the timer fires.
    e.open();
    try t.expect(e.isOpen());
    try t.expect(e.isMounted());
    // The stale timer now fires: it must NOT unmount the freshly re-opened overlay.
    try t.expect(!e.timerFired());
    try t.expect(e.isOpen());
    try t.expect(e.isMounted());
}

test "a hard close during the exit animation makes the stale timer a no-op" {
    var e: Exit = .{};
    e.open();
    try t.expect(e.requestClose());
    e.closeInstant();
    try t.expect(!e.isMounted());
    // The earlier timer fires against an already-closed overlay: no-op, no double unmount.
    try t.expect(!e.timerFired());
    try t.expect(!e.isMounted());
}

test "closeInstant from open skips the animation" {
    var e: Exit = .{};
    e.open();
    e.closeInstant();
    try t.expect(!e.isMounted());
    try t.expect(!e.isClosing());
}

test "timerFired on an open overlay never unmounts it" {
    var e: Exit = .{};
    e.open();
    try t.expect(!e.timerFired());
    try t.expect(e.isOpen());
}
