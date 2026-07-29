//! The API card's state: whether the card the status chip opens is up, and the handlers behind it.
//! status_indicator.zx is the markup; connection.zig owns the backend state the card configures.
//!
//! The card is the bell's and the gear's third: a top-bar control that drops a card from under the
//! bar rather than taking a dock and pushing the conversation aside. Opening it closes the other two,
//! arbitrated in topbar_menus.zig.
//!
//! THE CARD AND THE SETUP DOCK'S API SECTION SHOW THE SAME BODY, and connections_body.zx names its
//! fields with element ids (#llama-url, #conn-api-key, #conn-status) that connection.zig looks up by
//! id. Two mounts at once would give Connect the dock's URL box and write its progress into the
//! dock's status line, behind the card being read. So the two are mutually exclusive: opening the
//! card shuts a dock that is showing API (topbar_menus.zig), and a dock arriving on API shuts the
//! card (ui.zig). The rule lives at those two call sites rather than here, which keeps this module
//! ignorant of the dock exactly as notify_bell_state is ignorant of the gear.

const std = @import("std");
const zx = @import("zx");

const regions = @import("../shell/regions.zig");
const overlay_exit = @import("../platform/overlay_exit.zig");
const dom_event = @import("../platform/dom_event.zig");

/// The card's open/exit phase. `closing` keeps the card mounted through its `drawer-out` fade so the
/// exit has a node to run on; the timer below unmounts it. See overlay_exit.zig for the re-open guard.
var exit: overlay_exit.Exit = .{};

/// drawer-out is 200ms; unmount a hair later so the fade fully plays before the node leaves.
const close_ms: u32 = 220;

pub fn isOpen() bool {
    return exit.isOpen();
}

/// Rendered while open OR fading out, so the exit animation has a node.
pub fn isMounted() bool {
    return exit.isMounted();
}

/// The card is leaving: the markup swaps to the exit class and drops its pointer events.
pub fn isClosing() bool {
    return exit.isClosing();
}

pub fn expandedStr() []const u8 {
    return if (exit.isOpen()) "true" else "false";
}

/// Close on behalf of another surface: the other top-bar menus (topbar_menus.zig) and a dock
/// arriving on the API section (ui.zig). A no-op when already shut, so a caller can call it
/// unconditionally. Leaves focus ALONE, because the thing taking over is where focus belongs.
pub fn closeIfOpen() void {
    if (exit.isOpen()) closeCardInner(false);
}

pub fn onToggle(_: zx.client.Event) void {
    if (exit.isOpen()) {
        closeCard();
        return;
    }
    exit.open();
    regions.bumpShell();
    // The bump rendered synchronously, so the target exists. Focus enters the card so Escape reaches
    // its handler (WD39).
    focusId("api-popover");
}

pub fn onClose(_: zx.client.Event) void {
    closeCard();
}

/// Escape closes the card, the keyboard twin of its close button (WD37). Bound on the card, which
/// holds focus while it is open; ziex dispatches from the event target upward, so a key pressed
/// anywhere inside reaches this. Guarded on `isOpen` so a key during the fade-out is ignored.
///
/// STOPPED once consumed, the bell's and the gear's rule: otherwise the same Escape reaches
/// ui.onPageKey and also tears down an open side dock under a card the user only meant to dismiss.
/// The backend dropdown inside the body stops its own Escape before this, so a key aimed at the open
/// menu closes the menu and leaves the card up.
pub fn onKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    if (!exit.isOpen()) return;
    const key = ev.key() orelse return;
    defer zx.allocator.free(key);
    if (!std.mem.eql(u8, key, "Escape")) return;
    ev.preventDefault();
    ev.stopPropagation();
    closeCard();
}

/// Start the exit animation: keep the card mounted with its `drawer-out` class, hand focus back to
/// the chip NOW so the closing card never holds it (WD39), and arm the unmount timer. A re-open
/// before it fires flips the phase back to open, so the timer becomes a no-op (overlay_exit.zig).
fn closeCard() void {
    closeCardInner(true);
}

/// `restore_focus` is false only for the paths where another surface is taking focus.
fn closeCardInner(restore_focus: bool) void {
    if (!exit.requestClose()) return;
    regions.bumpShell();
    if (restore_focus) focusId("conn-chip");
    if (zx.platform.role == .client) _ = zx.client.setTimeout(closeTick, close_ms);
}

/// The exit timer fired: unmount the card iff it is still closing.
fn closeTick() void {
    if (exit.timerFired()) regions.bumpShell();
}

fn focusId(id: []const u8) void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(zx.allocator, id) orelse return;
    defer el.deinit();
    el.ref.call(void, "focus", .{}) catch {};
}
