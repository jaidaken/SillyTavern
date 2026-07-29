//! The notification bell's half of the state: whether its card is up, the two faces the one button
//! wears, and the handlers. notify_bell.zx is the markup; notifications.zig owns the store, the
//! unread count and the read receipt.
//!
//! The bell is a permanent top-bar button. Its card is not a panel: the history is a glance, not a
//! place you navigate to, so it drops from the bar instead of taking a dock and pushing the
//! conversation aside. Opening it closes the system card, arbitrated in topbar_menus.zig.

const std = @import("std");
const zx = @import("zx");

const notifications = @import("./notifications.zig");
const regions = @import("../shell/regions.zig");
const overlay_exit = @import("../platform/overlay_exit.zig");
const dom_event = @import("../platform/dom_event.zig");

/// The popover's open/exit phase. `closing` keeps the card mounted through its `drawer-out` fade so
/// the exit has a node to run on; the timer below unmounts it. See overlay_exit.zig for the guard.
var exit: overlay_exit.Exit = .{};

/// drawer-out is 200ms; unmount a hair later so the fade fully plays.
const close_ms: u32 = 220;

pub fn isOpen() bool {
    return exit.isOpen();
}

/// Rendered while open OR fading out, so the exit animation has a node.
pub fn isMounted() bool {
    return exit.isMounted();
}

/// The card is leaving: the markup swaps to the exit class and drops pointer events.
pub fn isClosing() bool {
    return exit.isClosing();
}

/// Close on behalf of the other top-bar menu (topbar_menus.zig). A no-op when already shut, so the
/// arbiter can call it unconditionally. Leaves focus ALONE: the card is being swapped for the system
/// card, so pulling focus onto the bell would steal it from the button the user just pressed.
pub fn closeIfOpen() void {
    if (exit.isOpen()) closePopoverInner(false);
}

/// The COUNT is the part that keys on unread, so a quiet app shows a bell with nothing on it. Empty
/// while the popover is open: opening marks everything read, and anything arriving after that is
/// already visible in the list under the pointer.
///
/// Copied onto the RENDER ARENA, never handed out as a slice of a local buffer: the component holds
/// the text until the vdom is patched, which is long after this frame returns. The first cut passed
/// a stack array in and the count rendered as one blank character.
pub fn countText(arena: std.mem.Allocator) []const u8 {
    if (exit.isOpen()) return "";
    var buf: [4]u8 = undefined;
    const text = notifications.badgeText(&buf);
    if (text.len == 0) return "";
    return arena.dupe(u8, text) catch "9+";
}

pub fn hasCount() bool {
    return !exit.isOpen() and notifications.unreadCount() > 0;
}

/// A bell glyph with a "3" on it names nothing, so the button says what it holds and what the click
/// will do (WD38). Reads as the plain thing when there is nothing new.
pub fn buttonLabel(arena: std.mem.Allocator) []const u8 {
    if (exit.isOpen()) return "Close notifications";
    const n = notifications.unreadCount();
    if (n == 0) return "Notifications";
    if (n == 1) return "Notifications, 1 unread";
    return std.fmt.allocPrint(arena, "Notifications, {d} unread", .{n}) catch "Notifications, unread";
}

pub fn expandedStr() []const u8 {
    return if (exit.isOpen()) "true" else "false";
}

pub fn onToggle(_: zx.client.Event) void {
    if (exit.isOpen()) {
        closePopover();
        return;
    }
    exit.open();
    notifications.markAllRead();
    regions.bumpShell();
}

pub fn onClose(_: zx.client.Event) void {
    closePopover();
}

/// Escape dismisses the popover, the keyboard twin of its close button (WD37). Bound on the badge
/// and on the popover itself: the badge keeps focus after the click that opened it, and focus moves
/// into the card only once the user tabs there.
///
/// The key is STOPPED once it is consumed, so it does not also reach ui.onPageKey on the shell root
/// and tear the whole dock down under a card the user only meant to dismiss (the innermost
/// dismissable wins, the convention the dropdown menus already follow). ziex walks up from the
/// event target and honours cancelBubble, so stopping here ends the walk. Without it the layering
/// held only by accident: closing the card unmounts the badge, and a detached node has no parent
/// for the walk to continue through.
pub fn onKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    if (!exit.isOpen()) return;
    const key = ev.key() orelse return;
    defer zx.allocator.free(key);
    if (!std.mem.eql(u8, key, "Escape")) return;
    ev.stopPropagation();
    closePopover();
}

/// Start the exit animation: keep the card mounted with its `drawer-out` class, hand focus back to
/// the bell NOW so the closing card never holds it (WD39), and arm the unmount timer. A re-open
/// before it fires flips the phase back to open, so the timer becomes a no-op (overlay_exit.zig).
///
/// Closing never marks read: a toast that arrived while the card was up would otherwise be read
/// before anyone saw it. Opening IS the read receipt (markAllRead in onToggle), the behaviour the
/// drawer had, so the count clears as the list is shown rather than needing a second gesture.
fn closePopover() void {
    closePopoverInner(true);
}

/// `restore_focus` is false only for the arbiter's swap path, where another control is taking focus.
fn closePopoverInner(restore_focus: bool) void {
    if (!exit.requestClose()) return;
    regions.bumpShell();
    if (restore_focus) focusId("notify-bell");
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
