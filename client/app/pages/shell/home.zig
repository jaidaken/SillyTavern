//! The home region's logic: the recent-chats fetch, its four-state machine, and the row actions
//! (open / resume-last / rename-delete stubs). Zig owns the data and state; home_body.zx reads the
//! getters below and delegates its handlers here. Rendered as a fourth grid sibling shown when no
//! chat is open (page.zx), it replaces char_api's old silent auto-open with a landing the user picks
//! from.
//!
//! zx-importing (net + the Fetch.Response callback), so browser-verified via the interactions gate
//! (ZX5), not `zig build test`.

const std = @import("std");
const zx = @import("zx");

const net = @import("../platform/net.zig");
const data = @import("../cast/char_data.zig");
const datetime = @import("../platform/datetime.zig");
const char_store = @import("../cast/character_store.zig");
const store = @import("../platform/store.zig");
const char_api = @import("../cast/char_api.zig");
const regions = @import("./regions.zig");
// w3-grp
const group_store = @import("../cast/group_store.zig");
const group_actions = @import("../cast/group_actions.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.home);

/// v1 caps the recent list; pins and an assistant surface are a later wave.
const RECENT_MAX = 24;
const PREVIEW_CAP = 120;

pub const RecentState = enum { idle, loading, ready, err };

/// One recent conversation. All slices are owned in page_gpa and freed on the next load; the display
/// name is resolved at render time (rowDisplayName) because the character store may load after this.
pub const RecentRow = struct {
    avatar: []const u8,
    file_name: []const u8,
    preview: []const u8,
    when: []const u8,
    // w3-grp: the group id when this is a group chat ("" = character chat).
    group: []const u8 = "",
};

/// The recent-chats response subset. The endpoint returns ~7 fields; Response.json ignores the rest
/// (same contract char_data.CharacterJson relies on). `avatar` is set for character chats, `group`
/// for group chats; v1 lists only character chats (a group has no character to open).
const RecentJson = struct {
    file_name: []const u8 = "",
    mes: []const u8 = "",
    // {number|string}, and BOTH shapes are real (src/endpoints/chats.js:369,380 type it that way):
    // a populated chat sends send_date (:403), an EMPTY one sends stats.mtimeMs, a bare number
    // (:450). Typed []const u8 this field did not merely mis-date that row, it failed the whole
    // array parse and dropped the landing into its error state. datetime.zig reads either.
    last_mes: std.json.Value = .null,
    avatar: []const u8 = "",
    group: []const u8 = "",
};

var state: RecentState = .idle;
var rows: []RecentRow = &.{};

pub fn recentState() RecentState {
    return state;
}

pub fn recentRows() []const RecentRow {
    return rows;
}

/// True when a chat is on screen, so the home landing hides behind it. Keys on the display store
/// (a demo seed or an opened chat fills it) and the selection, so an opened-but-empty chat still hides
/// home.
pub fn chatShowing() bool {
    return store.slice().len > 0 or char_store.selectedIndex() != null;
}

/// Called from Home's first client render: kick the recent load once. Idempotent; re-renders that
/// follow a load see .ready/.err and do not refetch.
pub fn ensureLoaded() void {
    if (state == .idle) loadRecent();
    // w3-grp: group rows name themselves off the roster, so the landing warms it alongside.
    group_actions.ensureLoaded();
}

/// Fetch the recent conversations. Sets .loading and re-renders, then onRecentDone lands the rows.
pub fn loadRecent() void {
    if (zx.platform.role != .client) return;
    state = .loading;
    regions.bumpHome();
    const body = std.json.Stringify.valueAlloc(alloc, .{ .max = RECENT_MAX }, .{}) catch {
        state = .err;
        regions.bumpHome();
        return;
    };
    defer alloc.free(body);
    net.request("/api/chats/recent", body, 0, onRecentDone, .{});
}

/// Retry button target: same as the initial load.
pub fn retryRecent() void {
    loadRecent();
}

fn onRecentDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (res == null or status == 0) {
        log.err("recent load failed: network error", .{});
        setError();
        return;
    }
    if (status < 200 or status >= 300) {
        log.warn("recent fetch returned {d}", .{status});
        setError();
        return;
    }
    const parsed = res.?.json([]RecentJson) catch |err| {
        log.warn("recent response is not a chat array: {s}", .{@errorName(err)});
        setError();
        return;
    };
    defer parsed.deinit();
    rebuildRows(parsed.value) catch |err| {
        log.err("recent rows rebuild failed: {s}", .{@errorName(err)});
        setError();
        return;
    };
    state = .ready;
    log.info("loaded {d} recent conversations", .{rows.len});
    regions.bumpHome();
}

fn setError() void {
    state = .err;
    regions.bumpHome();
}

fn rebuildRows(list: []const RecentJson) !void {
    freeRows();
    const now = nowMs();
    var out: std.ArrayList(RecentRow) = .empty;
    errdefer {
        for (out.items) |r| freeRow(r);
        out.deinit(alloc);
    }
    for (list) |rj| {
        // w3-grp: a row is openable when it names a character OR a group; anything else is noise.
        if (rj.avatar.len == 0 and rj.group.len == 0) continue;
        try out.append(alloc, try makeRow(rj, now));
    }
    rows = try out.toOwnedSlice(alloc);
}

fn makeRow(rj: RecentJson, now: f64) !RecentRow {
    const avatar = try alloc.dupe(u8, rj.avatar);
    errdefer alloc.free(avatar);
    const file_name = try alloc.dupe(u8, rj.file_name);
    errdefer alloc.free(file_name);
    const preview = try dupePreview(rj.mes);
    errdefer alloc.free(preview);
    const when = try formatWhen(rj.last_mes, now);
    errdefer alloc.free(when);
    const group = try alloc.dupe(u8, rj.group);
    return .{ .avatar = avatar, .file_name = file_name, .preview = preview, .when = when, .group = group };
}

/// Copies the preview, capped to PREVIEW_CAP bytes on a UTF-8 boundary so a truncation never splits a
/// codepoint. Interpolated as escaped text in the markup (WD47), never a raw-HTML sink.
fn dupePreview(mes: []const u8) ![]u8 {
    if (mes.len <= PREVIEW_CAP) return alloc.dupe(u8, mes);
    var cut: usize = PREVIEW_CAP;
    while (cut > 0 and (mes[cut] & 0xC0) == 0x80) cut -= 1;
    const ellipsis = "\u{2026}";
    const out = try alloc.alloc(u8, cut + ellipsis.len);
    @memcpy(out[0..cut], mes[0..cut]);
    @memcpy(out[cut..], ellipsis);
    return out;
}

fn formatWhen(last_mes: std.json.Value, now_ms: f64) ![]u8 {
    const then_ms = datetime.timestampMsFromJson(last_mes) orelse std.math.nan(f64);
    var buf: [32]u8 = undefined;
    return alloc.dupe(u8, datetime.relativeText(&buf, then_ms, now_ms));
}

/// Wall-clock epoch ms off `performance`, NOT `Date.now()`: jsz resolves a property by walking a js
/// VALUE, and a static hanging off a function object does not resolve, so `Date.now()` answers
/// error.InvalidType and every row here read "recently" forever. `performance` is a plain object, so
/// its `now` IS reachable, and timeOrigin + now() is the same instant.
fn nowMs() f64 {
    if (zx.platform.role != .client) return 0;
    const perf = zx.client.js.global.get(zx.client.js.Object, "performance") catch return 0;
    defer perf.deinit();
    const origin = perf.get(f64, "timeOrigin") catch return 0;
    const since = perf.call(f64, "now", .{}) catch return 0;
    return origin + since;
}

/// Display name for a row: the character store's name when the avatar matches a loaded character,
/// else the file-name stem (drops the extension and a trailing " - <date>"). Render-time so a store
/// that loads after the recent fetch still names the rows. Owned by the caller's allocator (the
/// render arena).
pub fn rowDisplayName(arena: std.mem.Allocator, r: RecentRow) []const u8 {
    // w3-grp: a group row names itself off the roster; the file stem covers a roster that has not
    // loaded yet (the roster bump re-renders home when it lands).
    if (r.group.len > 0) {
        if (group_store.byId(r.group)) |g| return g.name;
        return fileStem(arena, r.file_name);
    }
    for (char_store.slice()) |c| {
        if (std.mem.eql(u8, c.avatar, r.avatar)) return c.name;
    }
    return fileStem(arena, r.file_name);
}

fn fileStem(arena: std.mem.Allocator, file_name: []const u8) []const u8 {
    var stem = file_name;
    if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot| stem = stem[0..dot];
    if (std.mem.lastIndexOf(u8, stem, " - ")) |sep| stem = stem[0..sep];
    return arena.dupe(u8, stem) catch stem;
}

/// Avatar thumbnail URL for a row. Routes through char_data.thumbUrl so the avatar filename is
/// percent-encoded (a space or special byte in the name would otherwise break the src). Owned by
/// the render arena.
pub fn rowAvatarUrl(arena: std.mem.Allocator, r: RecentRow) []const u8 {
    // w3-grp: a group row wears its first member's avatar (group_body's rule); imageless until the
    // roster loads or when the group is memberless.
    if (r.group.len > 0) {
        const g = group_store.byId(r.group) orelse return "";
        const members = g.memberSlice();
        if (members.len == 0) return "";
        return data.thumbUrl(arena, "avatar", members[0]) catch "";
    }
    return data.thumbUrl(arena, "avatar", r.avatar) catch "";
}

// ---- row actions ----------------------------------------------------------------------------

/// Open the chat for the recent row at `index`: match its avatar to a loaded character and open that
/// character's chat (char_api owns the load). A row whose character is not in the store (deleted, or
/// characters not yet loaded) logs and stands down.
pub fn openRow(index: usize) void {
    if (index >= rows.len) return;
    // w3-grp: a group row routes to the group open path (roster select + the send side's hook).
    if (rows[index].group.len > 0) {
        log.info("open recent row {d}: group {s}", .{ index, rows[index].group });
        group_actions.openGroupById(rows[index].group);
        return;
    }
    const avatar = rows[index].avatar;
    const ci = charIndexByAvatar(avatar) orelse {
        log.warn("open recent: no loaded character for avatar {s}", .{avatar});
        return;
    };
    log.info("open recent row {d}: character index {d}", .{ index, ci });
    char_api.loadCharacterChat(ci);
}

/// Resume the most recent conversation: the explicit home action that replaces the old silent
/// auto-open. Opens the character with the newest date_last_chat (char_api owns the load).
pub fn resumeLast() void {
    const chars = char_store.slice();
    const best = data.mostRecentIndex(chars) orelse {
        log.debug("resume last: no characters loaded", .{});
        return;
    };
    log.info("resume last: character index {d} ({s})", .{ best, chars[best].name });
    char_api.loadCharacterChat(best);
}

/// Rename/delete a recent conversation. STUBBED for v1: the chat-lifecycle routes (rename/delete a
/// chat file) land in a later wave, so the affordances render but only report intent. Not a silent
/// no-op: it logs so the wiring gap is visible.
pub fn renameRow(index: usize) void {
    if (index >= rows.len) return;
    log.info("rename recent row {d}: chat rename wires in the chat-lifecycle wave", .{index});
}

pub fn deleteRow(index: usize) void {
    if (index >= rows.len) return;
    log.info("delete recent row {d}: chat delete wires in the chat-lifecycle wave", .{index});
}

fn charIndexByAvatar(avatar: []const u8) ?usize {
    for (char_store.slice(), 0..) |c, i| {
        if (std.mem.eql(u8, c.avatar, avatar)) return i;
    }
    return null;
}

fn freeRows() void {
    for (rows) |r| freeRow(r);
    if (rows.len > 0) alloc.free(rows);
    rows = &.{};
}

fn freeRow(r: RecentRow) void {
    alloc.free(r.avatar);
    alloc.free(r.file_name);
    alloc.free(r.preview);
    alloc.free(r.when);
    alloc.free(r.group);
}
