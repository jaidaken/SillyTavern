//! The notification bell's half of the state: whether its popover is up, the two faces the one
//! button wears, and the handlers. notify_bell.zx is the markup; notifications.zig owns the store,
//! the unread count and the read receipt.
//!
//! The bell replaces the one that used to sit in the 13-icon topbar. It is not a panel: the history
//! is a glance, not a place you navigate to, so it opens beside the tab it belongs to instead of
//! taking a dock and pushing the conversation aside.

const std = @import("std");
const zx = @import("zx");

const notifications = @import("./notifications.zig");
const regions = @import("../shell/regions.zig");
const edgetabs_state = @import("../nav/edgetabs_state.zig");

var open = false;

pub fn isOpen() bool {
    return open;
}

/// The bell rides the CAST TAB'S REVEAL: it is there whenever that tab is, and gone whenever it is.
///
/// The alternative shapes both fail. A bell that keys on the unread count alone can only be reached
/// by being lucky enough to have unread items, and nothing you have already read is ever reviewable
/// again. A permanently-visible bell costs resting chrome, which is the thing this whole rework is
/// removing. Reaching for the right edge is already the gesture that summons navigation, so arriving
/// with the tab costs nothing at rest and keeps the history always reachable.
///
/// It also stays while its own popover is up, whatever the pointer is doing: the button that opened
/// the card is the button that closes it, and it cannot fade out from under that job.
pub fn bellShown() bool {
    return open or edgetabs_state.tabShown(.right);
}

/// The COUNT is the part that keys on unread, so a quiet app shows a bell with nothing on it. Empty
/// while the popover is open: opening marks everything read, and anything arriving after that is
/// already visible in the list under the pointer.
///
/// Copied onto the RENDER ARENA, never handed out as a slice of a local buffer: the component holds
/// the text until the vdom is patched, which is long after this frame returns. The first cut passed
/// a stack array in and the count rendered as one blank character.
pub fn countText(arena: std.mem.Allocator) []const u8 {
    if (open) return "";
    var buf: [4]u8 = undefined;
    const text = notifications.badgeText(&buf);
    if (text.len == 0) return "";
    return arena.dupe(u8, text) catch "9+";
}

pub fn hasCount() bool {
    return !open and notifications.unreadCount() > 0;
}

/// A bell glyph with a "3" on it names nothing, so the button says what it holds and what the click
/// will do (WD38). Reads as the plain thing when there is nothing new.
pub fn buttonLabel(arena: std.mem.Allocator) []const u8 {
    if (open) return "Close notifications";
    const n = notifications.unreadCount();
    if (n == 0) return "Notifications";
    if (n == 1) return "Notifications, 1 unread";
    return std.fmt.allocPrint(arena, "Notifications, {d} unread", .{n}) catch "Notifications, unread";
}

pub fn expandedStr() []const u8 {
    return if (open) "true" else "false";
}

pub fn onToggle(_: zx.client.Event) void {
    setOpen(!open);
}

pub fn onClose(_: zx.client.Event) void {
    setOpen(false);
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
    if (!open) return;
    const key = ev.key() orelse return;
    defer zx.allocator.free(key);
    if (!std.mem.eql(u8, key, "Escape")) return;
    ev.stopPropagation();
    setOpen(false);
}

/// Opening IS the read receipt (the behaviour the drawer had), so the count clears as the list is
/// shown rather than needing a second gesture. Closing never marks: a toast that arrived while the
/// card was up would otherwise be read before anyone saw it.
fn setOpen(next: bool) void {
    open = next;
    if (next) notifications.markAllRead();
    regions.bumpShell();
}
