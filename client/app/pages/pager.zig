//! Reverse-lazy reader paging state: the change token, the total, the has-more flag, and the
//! avatars a prepended batch needs. The scroll/fetch pump lives in the JS glue (ZX16); this module
//! owns the request body it sends, the parse of the page it gets back, and the prepend into the
//! store. `window_offset` itself lives in `store` (the render key needs it); the pump reads it here
//! via `nextBody`. One page in flight at a time, guarded by `in_flight`.

const std = @import("std");
const store = @import("./store.zig");
const data = @import("./char_data.zig");
const regions = @import("./regions.zig");
const char_store = @import("./character_store.zig"); // w3-chatref: group rows resolve avatars by name
const group_store = @import("./group_store.zig"); // w3-chatref

const alloc = @import("./character_store.zig").page_gpa;
const log = std.log.scoped(.net);

/// Tail window size on open (fills a normal viewport) and the older-batch size per scroll-up
/// prepend. Operator-tunable, one place.
pub const TAIL_LIMIT: usize = 50;
pub const BATCH: usize = 100;
/// Ceiling on the send-time prompt-window fetch (invariant 2): the model sees its own budgeted spine
/// window, fetched separately from the display tail. Generous so the char budget, not this count, is
/// the usual bound; a chat with more messages than this within budget under-fills (accepted).
pub const PROMPT_LIMIT: usize = 300;

var avatar_url: []u8 = &.{};
var file_name: []u8 = &.{};
// w3-chatref: the open GROUP chat's file id; group mode iff non-empty (solo fields then empty).
var group_chat_id: []u8 = &.{};
var char_name: []u8 = &.{};
var char_avatar: []u8 = &.{};
var persona_avatar: []u8 = &.{};
var change_token: []u8 = &.{};
/// Whole-file version token from /get, distinct from `change_token` (the tail token). A message
/// mutation must present THIS; the tail token 409s by design. Set on every chat open/resync.
var full_token: []u8 = &.{};
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

/// Records the paging state for a freshly opened chat: the ref to page against (solo or group,
/// invariant 5: one reader path), the avatars a prepended batch wears, and the token/total/has-more
/// from the tail response. Clears the in-flight guard. Called by `char_api` once the tail window is
/// seeded into the store. For a group ref `char_name`/`char_avatar` are the roster fallbacks (a row
/// resolves its own member's avatar by name).
pub fn open(
    ref: data.ChatRef,
    char_name_src: []const u8,
    char_avatar_src: []const u8,
    persona_avatar_src: []const u8,
    total: usize,
    more: bool,
    token: []const u8,
) void {
    switch (ref) { // w3-chatref
        .solo => |s| {
            setOwned(&avatar_url, s.avatar);
            setOwned(&file_name, s.file);
            setOwned(&group_chat_id, "");
        },
        .group => |g| {
            setOwned(&avatar_url, "");
            setOwned(&file_name, "");
            setOwned(&group_chat_id, g.id);
        },
    }
    setOwned(&char_name, char_name_src);
    setOwned(&char_avatar, char_avatar_src);
    setOwned(&persona_avatar, persona_avatar_src);
    setOwned(&change_token, token);
    total_items = total;
    has_more_before = more;
    in_flight = false;
}

/// w3-chatref: the open chat's ref, rebuilt from the owned identity fields; null = no open chat.
fn currentRef() ?data.ChatRef {
    if (group_chat_id.len > 0) return .{ .group = .{ .id = group_chat_id } };
    const ref = data.ChatRef{ .solo = .{ .avatar = avatar_url, .file = file_name } };
    return if (ref.valid()) ref else null;
}

/// Drops all paging state (chat closed or store cleared), so a stray late completion no longer
/// prepends into the wrong chat.
pub fn reset() void {
    inline for (.{ &avatar_url, &file_name, &group_chat_id, &char_name, &char_avatar, &persona_avatar, &change_token, &full_token }) |field| {
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

/// The open chat's current file-version token. The reader (prepend) and the append path (char_api)
/// share it: both send it for optimistic concurrency and adopt the token the server returns.
pub fn currentToken() []const u8 {
    return change_token;
}

/// Adopt a new file-version token after an append changed the file, so the next scroll-up prepend
/// carries the fresh token instead of a stale one that would 409.
pub fn adoptToken(new_token: []const u8) void {
    setOwned(&change_token, new_token);
}

/// The whole-file token a message mutation must present (never `currentToken`, which is the tail
/// token and 409s). Empty until the first /get sets it.
pub fn fullToken() []const u8 {
    return full_token;
}

/// Record the whole-file token from a /get response (char_api on open/resync) or adopt the fresh one
/// a successful mutation returns, so the next mutation carries a current token instead of a 409.
pub fn setFullToken(new_token: []const u8) void {
    setOwned(&full_token, new_token);
}

/// Builds the JSON body for the next older page, or returns 0 when there is nothing to fetch or a
/// page is already in flight. On success sets the in-flight guard and returns `ptr << 32 | len`
/// into a reused static buffer the JS pump reads synchronously before its next call.
pub fn nextBody() u64 {
    if (in_flight or !has_more_before) return 0;
    const ref = currentRef() orelse return 0; // w3-chatref: ref-agnostic body (invariant 5)
    const json = data.pageBody(alloc, ref, .{
        .limit = BATCH,
        .before_index = store.global.window_offset,
        .change_token = change_token,
    }) catch return 0;
    defer alloc.free(json);
    if (json.len > body_buf.len) return 0;
    @memcpy(body_buf[0..json.len], json);
    in_flight = true;
    return (@as(u64, @intFromPtr(&body_buf[0])) << 32) | @as(u64, json.len);
}

/// w3-chatref: the route the JS pump posts `nextBody` to (solo vs group), packed ptr<<32|len of a
/// static string. 0 = no open chat.
pub fn pageUrl() u64 {
    const ref = currentRef() orelse return 0;
    const url = ref.url();
    return (@as(u64, @intFromPtr(url.ptr)) << 32) | @as(u64, url.len);
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
    // w3-chatref: group thumbs live only until prependSealed copies them into the store.
    var member_thumbs: std.ArrayList([]u8) = .empty;
    defer {
        for (member_thumbs.items) |t| alloc.free(t);
        member_thumbs.deinit(alloc);
    }
    for (page.messages, 0..) |m, i| {
        const sender = if (m.name.len > 0) m.name else if (m.is_user) "You" else char_name;
        const avatar = if (m.is_user)
            persona_avatar
        else if (group_chat_id.len > 0)
            (memberThumb(m.name, &member_thumbs) orelse char_avatar) // w3-chatref
        else
            char_avatar;
        items[i] = .{ .name = sender, .body = m.mes, .avatar = avatar, .reasoning = m.reasoning }; // w3-reason
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
    return has_more_before and !in_flight and !resyncing and currentRef() != null;
}

// w3-chatref: a prepended group row is attributed per message name (a former member's rows must
// still resolve, so the lookup spans the whole character store). Owned thumb parked on `thumbs`.
fn memberThumb(name: []const u8, thumbs: *std.ArrayList([]u8)) ?[]const u8 {
    const ci = group_store.characterIndexByName(name) orelse return null;
    const c = char_store.slice()[ci];
    if (c.avatar.len == 0) return null;
    const t = data.thumbUrl(alloc, "avatar", c.avatar) catch return null;
    thumbs.append(alloc, t) catch {
        alloc.free(t);
        return null;
    };
    return t;
}

/// Clears the in-flight guard without applying a page. The JS pump calls this when it drops a
/// response (a 409 re-sync or a network error) so the next scroll can retry.
pub fn abort() void {
    in_flight = false;
}
