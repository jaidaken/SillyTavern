//! Reverse-lazy reader paging state: the change token, the total, the has-more flag, and the
//! avatars a prepended batch needs. The scroll/fetch pump lives in the JS glue (ZX16); this module
//! owns the request body it sends, the parse of the page it gets back, and the prepend into the
//! store. `window_offset` itself lives in `store` (the render key needs it); the pump reads it here
//! via `nextBody`. One page in flight at a time, guarded by `in_flight`.

const std = @import("std");
const store = @import("./store.zig");
const data = @import("./char_data.zig");
const regions = @import("./regions.zig");

const alloc = @import("./character_store.zig").page_gpa;
const log = std.log.scoped(.net);

/// Tail window size on open (fills a normal viewport) and the older-batch size per scroll-up
/// prepend. Operator-tunable, one place.
pub const TAIL_LIMIT: usize = 50;
pub const BATCH: usize = 100;

var avatar_url: []u8 = &.{};
var file_name: []u8 = &.{};
var char_name: []u8 = &.{};
var char_avatar: []u8 = &.{};
var persona_avatar: []u8 = &.{};
var change_token: []u8 = &.{};
var total_items: usize = 0;
var has_more_before: bool = false;
var in_flight: bool = false;
/// A 409 re-sync reload is dispatched but not yet complete. Holds canPrepend false across the gap
/// so a stray scroll cannot re-fire the stale token into another 409.
var resyncing: bool = false;

var body_buf: [4096]u8 = undefined;

fn setOwned(dst: *[]u8, src: []const u8) void {
    if (dst.len > 0) alloc.free(dst.*);
    dst.* = alloc.dupe(u8, src) catch &.{};
}

/// Records the paging state for a freshly opened chat: the identity to page against, the avatars a
/// prepended batch wears, and the token/total/has-more from the tail response. Clears the in-flight
/// guard. Called by `char_api` once the tail window is seeded into the store.
pub fn open(
    avatar_url_src: []const u8,
    file_name_src: []const u8,
    char_name_src: []const u8,
    char_avatar_src: []const u8,
    persona_avatar_src: []const u8,
    total: usize,
    more: bool,
    token: []const u8,
) void {
    setOwned(&avatar_url, avatar_url_src);
    setOwned(&file_name, file_name_src);
    setOwned(&char_name, char_name_src);
    setOwned(&char_avatar, char_avatar_src);
    setOwned(&persona_avatar, persona_avatar_src);
    setOwned(&change_token, token);
    total_items = total;
    has_more_before = more;
    in_flight = false;
}

/// Drops all paging state (chat closed or store cleared), so a stray late completion no longer
/// prepends into the wrong chat.
pub fn reset() void {
    inline for (.{ &avatar_url, &file_name, &char_name, &char_avatar, &persona_avatar, &change_token }) |field| {
        if (field.len > 0) alloc.free(field.*);
        field.* = &.{};
    }
    total_items = 0;
    has_more_before = false;
    in_flight = false;
    resyncing = false;
}

/// Marks a 409 re-sync reload as in flight (canPrepend goes false until the reload's chat-open
/// clears it), so a stray scroll during the reload cannot re-fire the stale page.
pub fn beginResync() void {
    resyncing = true;
}

/// Clears the re-sync guard once the reload's completion (or its early abort) has run.
pub fn clearResync() void {
    resyncing = false;
}

/// Builds the JSON body for the next older page, or returns 0 when there is nothing to fetch or a
/// page is already in flight. On success sets the in-flight guard and returns `ptr << 32 | len`
/// into a reused static buffer the JS pump reads synchronously before its next call.
pub fn nextBody() u64 {
    if (in_flight or !has_more_before or avatar_url.len == 0 or file_name.len == 0) return 0;
    const json = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = avatar_url,
        .file_name = file_name,
        .paged = true,
        .before_index = store.global.window_offset,
        .limit = BATCH,
        .change_token = change_token,
    }, .{}) catch return 0;
    defer alloc.free(json);
    if (json.len > body_buf.len) return 0;
    @memcpy(body_buf[0..json.len], json);
    in_flight = true;
    return (@as(u64, @intFromPtr(&body_buf[0])) << 32) | @as(u64, json.len);
}

/// Parses a 200 page body and prepends its messages to the store head. Clears the in-flight guard,
/// updates the token/total/has-more, and bumps the message log once. Returns the number of messages
/// prepended (0 = nothing to add or a malformed body). `bytes` is borrowed; the JS pump frees it.
pub fn applyPage(bytes: []const u8) u32 {
    in_flight = false;
    const parsed = data.parseJson(std.json.Value, alloc, bytes) catch {
        log.warn("prepend page body unparseable", .{});
        return 0;
    };
    defer parsed.deinit();
    const page = data.parseChatPage(alloc, parsed.value) catch {
        log.err("prepend page: out of memory", .{});
        return 0;
    };
    defer data.freeChatPage(alloc, page);

    setOwned(&change_token, page.change_token);
    total_items = page.total_items;
    has_more_before = page.has_more_before;

    if (page.messages.len == 0) return 0;
    // Refuse a batch larger than window_offset: it would underflow the offset (silent UB in
    // ReleaseSmall). The server guarantees this; the boundary is untrusted, so guard it.
    if (page.messages.len > store.global.window_offset) {
        log.warn("prepend page overshoots window origin ({d} > {d}); refusing", .{ page.messages.len, store.global.window_offset });
        return 0;
    }

    const items = alloc.alloc(store.Incoming, page.messages.len) catch return 0;
    defer alloc.free(items);
    for (page.messages, 0..) |m, i| {
        const sender = if (m.name.len > 0) m.name else if (m.is_user) "You" else char_name;
        const avatar = if (m.is_user) persona_avatar else char_avatar;
        items[i] = .{ .name = sender, .body = m.mes, .avatar = avatar };
    }
    store.global.prependSealed(items) catch |err| {
        log.err("prepend into store failed: {s}", .{@errorName(err)});
        return 0;
    };
    regions.bumpMessageLog();
    log.debug("prepended {d} older messages, offset now {d}", .{ page.messages.len, store.global.window_offset });
    return @intCast(page.messages.len);
}

/// True while a chat with older history above the window is open and no page is in flight; the JS
/// pump gates a prefetch on this before reading `nextBody`.
pub fn canPrepend() bool {
    return has_more_before and !in_flight and !resyncing and avatar_url.len > 0;
}

/// Clears the in-flight guard without applying a page. The JS pump calls this when it drops a
/// response (a 409 re-sync or a network error) so the next scroll can retry.
pub fn abort() void {
    in_flight = false;
}
