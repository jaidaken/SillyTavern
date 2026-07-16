//! Pure row-presentation logic for the character list: the subtitle text (last-chat recency + chat
//! volume) and the hover-action table the markup loops over. zx-free so it joins the native
//! `zig build test` aggregator (ZX5); character_list.zx holds the DOM side, character_prefs.zig the
//! persistence.
//!
//! The subtitle replaces the description, which repeated the card blurb in a truncated line and told
//! you nothing you could act on. What the list is FOR is picking a chat to continue, so the row
//! carries when you last spoke and how much history is behind it.

const std = @import("std");
const data = @import("./char_data.zig");

/// A row-hover action. `id` is echoed as data-char-action and dispatched to the matching char_api
/// entry point; `icon` names a mask in the stylesheet's C-CHAR zone.
pub const RowAction = struct {
    id: []const u8,
    label: []const u8,
    icon: []const u8,
    danger: bool = false,
};

/// The row-hover cluster, in visual order. Delete sits last and wears the danger styling, so the
/// destructive control is never adjacent to the one you reach for most (rename).
pub const row_actions = [_]RowAction{
    .{ .id = "rename", .label = "Rename", .icon = "pencil" },
    .{ .id = "duplicate", .label = "Duplicate", .icon = "copy" },
    .{ .id = "export", .label = "Export", .icon = "download" },
    .{ .id = "delete", .label = "Delete", .icon = "trash", .danger = true },
};

/// Recency phrase for a last-chat stamp (epoch ms), written into `buf`. 0 means the character has no
/// chat directory at all, which reads as an invitation rather than a date. Past a week the exact date
/// carries more than a widening "34d ago", so it switches to the ISO date (matching home.zig's ladder).
pub fn lastChatText(buf: *[32]u8, date_last_chat_ms: u64, now_ms: f64) []const u8 {
    if (date_last_chat_ms == 0) return "No chats yet";
    const then_ms: f64 = @floatFromInt(date_last_chat_ms);
    const diff = now_ms - then_ms;
    if (!std.math.isFinite(diff) or diff < 0) return "recently";
    const secs: u64 = @intFromFloat(@trunc(diff / 1000.0));
    if (secs < 60) return "just now";
    const mins = secs / 60;
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{mins}) catch "recently";
    const hours = mins / 60;
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "recently";
    const days = hours / 24;
    if (days < 7) return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "recently";
    var date_buf: [10]u8 = undefined;
    const iso = data.isoDateFromMs(then_ms, &date_buf);
    return std.fmt.bufPrint(buf, "{s}", .{iso}) catch "recently";
}

/// Chat volume for `bytes` (the server's chat_size: the summed size of the character's chat files),
/// written into `buf`. Empty for 0 so a never-chatted row shows one phrase, not a "0 B".
///
/// This is NOT a message count. /api/characters/all reports only the byte size (characters.js
/// calculateChatSize sums fs.stat sizes), so a count would need the server to read every chat file
/// per list request. Flagged to the lead; the honest number ships meanwhile.
pub fn chatVolumeText(buf: *[16]u8, bytes: u64) []const u8 {
    if (bytes == 0) return "";
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024) return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{kb / 1024.0}) catch "";
}

const testing = std.testing;

test "lastChatText names the never-chatted case instead of dating it" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("No chats yet", lastChatText(&buf, 0, 1783800000000));
}

test "lastChatText steps minutes hours and days" {
    var buf: [32]u8 = undefined;
    const now: f64 = 1783800000000;
    try testing.expectEqualStrings("just now", lastChatText(&buf, 1783799970000, now));
    try testing.expectEqualStrings("5m ago", lastChatText(&buf, 1783799700000, now));
    try testing.expectEqualStrings("3h ago", lastChatText(&buf, 1783789200000, now));
    try testing.expectEqualStrings("2d ago", lastChatText(&buf, 1783627200000, now));
}

test "lastChatText switches to the ISO date past a week" {
    var buf: [32]u8 = undefined;
    // 1783800000000 is 2026-07-11; 30 days earlier is 2026-06-11.
    try testing.expectEqualStrings("2026-06-11", lastChatText(&buf, 1781208000000, 1783800000000));
}

test "lastChatText degrades a future or non-finite stamp to recently" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("recently", lastChatText(&buf, 1783900000000, 1783800000000));
    try testing.expectEqualStrings("recently", lastChatText(&buf, 1783700000000, std.math.nan(f64)));
}

test "chatVolumeText is empty at zero and scales past a kilobyte" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("", chatVolumeText(&buf, 0));
    try testing.expectEqualStrings("512 B", chatVolumeText(&buf, 512));
    try testing.expectEqualStrings("1.0 KB", chatVolumeText(&buf, 1024));
    try testing.expectEqualStrings("12.5 KB", chatVolumeText(&buf, 12800));
    try testing.expectEqualStrings("2.0 MB", chatVolumeText(&buf, 2097152));
}

test "row_actions carries delete last and marks it the only danger" {
    try testing.expectEqualStrings("delete", row_actions[row_actions.len - 1].id);
    var dangers: usize = 0;
    for (row_actions) |a| {
        try testing.expect(a.id.len > 0 and a.label.len > 0 and a.icon.len > 0);
        if (a.danger) dangers += 1;
    }
    try testing.expectEqual(@as(usize, 1), dangers);
}
