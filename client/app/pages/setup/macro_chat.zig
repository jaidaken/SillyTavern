//! The chat-state macro resolver: `{{lastMessage}}`, `{{lastUserMessage}}`, `{{lastSwipeId}}` and
//! friends, ported from the classic client's chat-macros.js.
//!
//! Pure and std-only: the caller owns the chat log and hands it in as a `State`, so this module never
//! touches the DOM, a global, or an allocator static. That keeps it native-testable (`zig build test`)
//! and lets the macro engine call it as one resolver among several, falling through on a name it does
//! not know.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One chat message, reduced to the fields the chat macros read.
///
/// `swipe_count` stands in for the classic `message.swipes` array length. Stock treats a message whose
/// `swipe_id` has run past the end of that array as a swipe still generating and skips it; the same
/// comparison here reproduces that, and the defaults (`swipe_id` 0, `swipe_count` 1) describe an
/// ordinary settled message that is never skipped.
pub const Msg = struct {
    name: []const u8 = "",
    mes: []const u8 = "",
    is_user: bool = false,
    is_system: bool = false,
    swipe_id: usize = 0,
    swipe_count: usize = 1,
};

/// The chat state the macros resolve against.
///
/// `first_included_id` is the caller's copy of `chat_metadata.lastInContextMessageId` (stock reads that
/// field for the macro named firstIncludedMessageId, script.js:6071) and `first_displayed_id` is the
/// mesid of the first rendered message, which stock scrapes off the DOM. Both are optional because
/// stock resolves them to an empty string until something sets them.
pub const State = struct {
    messages: []const Msg = &.{},
    first_included_id: ?usize = null,
    first_displayed_id: ?usize = null,
};

const Filter = enum { any, user, char };

/// The index of the last message matching `filter`, scanning newest first, or null when none matches.
///
/// `exclude_swipe_in_progress` skips a message whose swipe is still generating BEFORE the filter runs,
/// so such a message is passed over entirely rather than ending the scan (chat-macros.js:91).
fn lastMessageId(st: State, exclude_swipe_in_progress: bool, filter: Filter) ?usize {
    var i = st.messages.len;
    while (i > 0) {
        i -= 1;
        const m = st.messages[i];
        if (exclude_swipe_in_progress and m.swipe_id >= m.swipe_count) continue;
        const matches = switch (filter) {
            .any => true,
            .user => m.is_user and !m.is_system,
            .char => !m.is_user and !m.is_system,
        };
        if (matches) return i;
    }
    return null;
}

fn lastText(st: State, filter: Filter) []const u8 {
    const mid = lastMessageId(st, true, filter) orelse return "";
    return st.messages[mid].mes;
}

/// The chat-state macro `name` resolved against `st`, or null for a name this resolver does not know
/// (so the caller can fall through to another resolver and leave an unknown `{{macro}}` alone).
///
/// The caller owns the returned string and must free it with the same allocator. The result is always
/// a fresh copy, never a slice into `st`. A macro that has no value yet resolves to an empty owned
/// string, not null: stock's handlers coerce their null through `String(x ?? '')`, so `{{lastMessage}}`
/// on an empty chat renders as nothing rather than staying literal.
///
/// ```zig
/// const msgs = [_]Msg{.{ .mes = "hi", .is_user = true }};
/// const out = (try resolve(alloc, "lastMessage", .{ .messages = &msgs })).?;
/// defer alloc.free(out);
/// try std.testing.expectEqualStrings("hi", out);
/// ```
pub fn resolve(alloc: Allocator, name: []const u8, st: State) Allocator.Error!?[]u8 {
    if (std.mem.eql(u8, name, "lastMessage")) return try alloc.dupe(u8, lastText(st, .any));
    if (std.mem.eql(u8, name, "lastUserMessage")) return try alloc.dupe(u8, lastText(st, .user));
    if (std.mem.eql(u8, name, "lastCharMessage")) return try alloc.dupe(u8, lastText(st, .char));
    if (std.mem.eql(u8, name, "lastMessageId")) return try optionalNumber(alloc, lastMessageId(st, true, .any));
    if (std.mem.eql(u8, name, "firstIncludedMessageId")) return try optionalNumber(alloc, st.first_included_id);
    if (std.mem.eql(u8, name, "firstDisplayedMessageId")) return try optionalNumber(alloc, st.first_displayed_id);
    if (std.mem.eql(u8, name, "lastSwipeId")) {
        const mid = lastMessageId(st, false, .any) orelse return try alloc.dupe(u8, "");
        return try std.fmt.allocPrint(alloc, "{d}", .{st.messages[mid].swipe_count});
    }
    if (std.mem.eql(u8, name, "currentSwipeId")) {
        const mid = lastMessageId(st, false, .any) orelse return try alloc.dupe(u8, "");
        return try std.fmt.allocPrint(alloc, "{d}", .{st.messages[mid].swipe_id + 1});
    }
    if (std.mem.eql(u8, name, "allChatRange")) {
        if (st.messages.len == 0) return try alloc.dupe(u8, "");
        return try std.fmt.allocPrint(alloc, "0-{d}", .{st.messages.len - 1});
    }
    return null;
}

fn optionalNumber(alloc: Allocator, value: ?usize) Allocator.Error![]u8 {
    const v = value orelse return try alloc.dupe(u8, "");
    return try std.fmt.allocPrint(alloc, "{d}", .{v});
}

const testing = std.testing;

fn expectMacro(expected: []const u8, name: []const u8, st: State) !void {
    const out = (try resolve(testing.allocator, name, st)) orelse return error.UnknownMacro;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

const sample = [_]Msg{
    .{ .name = "Jamie", .mes = "first user line", .is_user = true },
    .{ .name = "Rita", .mes = "a char reply" },
    .{ .name = "Jamie", .mes = "second user line", .is_user = true },
    .{ .name = "Rita", .mes = "the newest reply", .swipe_id = 1, .swipe_count = 3 },
};

test "lastMessage resolves to the newest message text" {
    try expectMacro("the newest reply", "lastMessage", .{ .messages = &sample });
}

test "lastMessageId resolves to the newest index" {
    try expectMacro("3", "lastMessageId", .{ .messages = &sample });
}

test "lastUserMessage skips character messages" {
    try expectMacro("second user line", "lastUserMessage", .{ .messages = &sample });
}

test "lastCharMessage skips user messages" {
    try expectMacro("the newest reply", "lastCharMessage", .{ .messages = &sample });
}

test "a system message is invisible to the user and char macros but not to lastMessage" {
    const msgs = [_]Msg{
        .{ .mes = "user line", .is_user = true },
        .{ .mes = "char line" },
        .{ .mes = "system notice", .is_system = true },
    };
    const st = State{ .messages = &msgs };
    try expectMacro("system notice", "lastMessage", st);
    try expectMacro("user line", "lastUserMessage", st);
    try expectMacro("char line", "lastCharMessage", st);
}

test "a system message authored by the user is excluded from lastUserMessage" {
    const msgs = [_]Msg{
        .{ .mes = "real user line", .is_user = true },
        .{ .mes = "user-flagged system line", .is_user = true, .is_system = true },
    };
    try expectMacro("real user line", "lastUserMessage", .{ .messages = &msgs });
}

test "a message whose swipe is still generating is passed over" {
    const msgs = [_]Msg{
        .{ .mes = "settled reply" },
        .{ .mes = "", .swipe_id = 2, .swipe_count = 2 },
    };
    const st = State{ .messages = &msgs };
    try expectMacro("settled reply", "lastMessage", st);
    try expectMacro("0", "lastMessageId", st);
}

test "lastSwipeId counts the swipes of the newest message including one in progress" {
    const msgs = [_]Msg{
        .{ .mes = "settled reply" },
        .{ .mes = "", .swipe_id = 2, .swipe_count = 2 },
    };
    try expectMacro("2", "lastSwipeId", .{ .messages = &msgs });
    try expectMacro("3", "lastSwipeId", .{ .messages = &sample });
}

test "currentSwipeId is the one-based swipe index of the newest message" {
    try expectMacro("2", "currentSwipeId", .{ .messages = &sample });
    const msgs = [_]Msg{.{ .mes = "only" }};
    try expectMacro("1", "currentSwipeId", .{ .messages = &msgs });
}

test "firstIncludedMessageId and firstDisplayedMessageId resolve to their state values" {
    const st = State{ .messages = &sample, .first_included_id = 2, .first_displayed_id = 0 };
    try expectMacro("2", "firstIncludedMessageId", st);
    try expectMacro("0", "firstDisplayedMessageId", st);
}

test "an unset context boundary resolves to an empty string" {
    const st = State{ .messages = &sample };
    try expectMacro("", "firstIncludedMessageId", st);
    try expectMacro("", "firstDisplayedMessageId", st);
}

test "allChatRange spans zero to the last index and collapses to 0-0 for one message" {
    try expectMacro("0-3", "allChatRange", .{ .messages = &sample });
    const one = [_]Msg{.{ .mes = "only" }};
    try expectMacro("0-0", "allChatRange", .{ .messages = &one });
}

test "every macro resolves to an empty string on an empty chat" {
    const names = [_][]const u8{
        "lastMessage",             "lastMessageId",  "lastUserMessage", "lastCharMessage",
        "lastSwipeId",             "currentSwipeId", "allChatRange",    "firstIncludedMessageId",
        "firstDisplayedMessageId",
    };
    for (names) |n| try expectMacro("", n, .{});
}

test "a chat with no user message yet resolves lastUserMessage to empty" {
    const msgs = [_]Msg{.{ .mes = "greeting" }};
    const st = State{ .messages = &msgs };
    try expectMacro("", "lastUserMessage", st);
    try expectMacro("greeting", "lastCharMessage", st);
}

test "a chat of only user messages resolves lastCharMessage to empty" {
    const msgs = [_]Msg{.{ .mes = "hello", .is_user = true }};
    try expectMacro("", "lastCharMessage", .{ .messages = &msgs });
}

test "resolve returns null for a name it does not own" {
    const unknown = try resolve(testing.allocator, "char", .{ .messages = &sample });
    try testing.expect(unknown == null);
    const empty_name = try resolve(testing.allocator, "", .{ .messages = &sample });
    try testing.expect(empty_name == null);
}

test "resolve cleans up on every allocation failure" {
    const st = State{ .messages = &sample, .first_included_id = 1, .first_displayed_id = 0 };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, s: State) !void {
            const names = [_][]const u8{
                "lastMessage",             "lastMessageId",  "lastUserMessage", "lastCharMessage",
                "lastSwipeId",             "currentSwipeId", "allChatRange",    "firstIncludedMessageId",
                "firstDisplayedMessageId",
            };
            for (names) |n| {
                const out = (try resolve(alloc, n, s)) orelse unreachable;
                alloc.free(out);
            }
        }
    }.run, .{st});
}
