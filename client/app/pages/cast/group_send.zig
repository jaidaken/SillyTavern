//! Impure group-send driver (C-GRP 3c-B): walks a group_rotation queue one member at a time,
//! reusing the solo send machinery per member (char_api.launchGroupMember stashes the member's
//! card, fetches the group prompt window exactly like a solo send fetches its own, and the JS
//! pump streams + seals as usual). This file owns WHICH member runs and WHERE turns persist
//! (the group append route); char_api owns HOW a single turn is produced.
//!
//! Invariant 5: every turn, user and member alike, persists through the same /api/chats/append
//! route solo uses (the body carries group_id instead of avatar_url+file_name, resolved by the
//! server's ChatRef into groupChats/<id>.jsonl). Invariant 2: each member's prompt window is a
//! separate paged /api/chats/group/get fetch with the solo PROMPT_LIMIT, never the display tail.
//!
//! The rotation launches members strictly sequentially: the next stash begins only after the
//! prior member's seal, because char_api's pending-send slot is single (pend_active).

const std = @import("std");
const zx = @import("zx");

const rotation = @import("./group_rotation.zig");
const char_api = @import("./char_api.zig");
const reader = @import("../chat/reader.zig");
const char_store = @import("./character_store.zig");
const store = @import("../platform/store.zig");
const pager = @import("../chat/pager.zig");
const regions = @import("../shell/regions.zig");
const data = @import("./char_data.zig");
const net = @import("../platform/net.zig");

const alloc = char_store.page_gpa;
const grp_log = std.log.scoped(.group);

pub const GroupDef = struct {
    chat_id: []const u8,
    strategy: rotation.ActivationStrategy = .natural,
    allow_self_responses: bool = false,
    members: []const rotation.Member = &.{},
};

var rot: ?rotation.Rotation = null;
var chat_id_buf: []u8 = &.{};
/// The current member's launch is parked waiting for its deep-card fetch to settle.
var pending_launch: bool = false;
var deep_tried: bool = false;
/// char_api.chatLoadSeq at begin: a chat open or store rebuild mid-rotation makes the display
/// store someone else's, so the seal must not read its last message (solo send_seq parity).
var grp_seq: u32 = 0;

pub fn isActive() bool {
    return rot != null;
}

/// The append/window target while a rotation runs; null in solo mode.
pub fn chatId() ?[]const u8 {
    if (chat_id_buf.len == 0) return null;
    return chat_id_buf;
}

/// Door-export entry: a JSON group definition plus the user text. Returns 1 when the rotation
/// (or a memberless manual send) started. The buffer is borrowed; everything kept is duped.
pub fn beginSendJson(buf: []const u8) u32 {
    if (zx.platform.role != .client) return 0;
    const Wire = struct {
        chat_id: []const u8 = "",
        strategy: u8 = 0,
        allow_self_responses: bool = false,
        members: []const struct { avatar: []const u8 = "", name: []const u8 = "" } = &.{},
        text: []const u8 = "",
        manual_pick: ?usize = null,
    };
    const parsed = std.json.parseFromSlice(Wire, alloc, buf, .{ .ignore_unknown_fields = true }) catch {
        grp_log.warn("group send: malformed definition JSON", .{});
        return 0;
    };
    defer parsed.deinit();
    const w = parsed.value;
    const mems = alloc.alloc(rotation.Member, w.members.len) catch return 0;
    defer alloc.free(mems);
    for (w.members, 0..) |m, i| mems[i] = .{ .avatar = m.avatar, .name = m.name };
    const ok = beginSend(.{
        .chat_id = w.chat_id,
        .strategy = @enumFromInt(w.strategy),
        .allow_self_responses = w.allow_self_responses,
        .members = mems,
    }, w.text, w.manual_pick);
    return @intFromBool(ok);
}

/// Start a group send: select the rotation order, persist the user turn through the group
/// append route, then launch the first member. False when a rotation is already running or the
/// definition is unusable; the composer send stays untouched either way.
pub fn beginSend(def: GroupDef, user_text: []const u8, manual_pick: ?usize) bool {
    if (zx.platform.role != .client) return false;
    if (rot != null) {
        grp_log.warn("group send: a rotation is already running", .{});
        return false;
    }
    if (def.chat_id.len == 0 or user_text.len == 0) return false;
    const order = rotation.selectMembers(alloc, def.members, .{
        .strategy = def.strategy,
        .activation_text = user_text,
        .allow_self_responses = def.allow_self_responses,
        .is_user_input = true,
        .manual_pick = manual_pick,
    }) catch return false;
    defer alloc.free(order);

    const cid = alloc.dupe(u8, def.chat_id) catch return false;
    if (chat_id_buf.len > 0) alloc.free(chat_id_buf);
    chat_id_buf = cid;
    grp_seq = char_api.chatLoadSeq();
    appendUserTurn(user_text);

    // Manual strategy with no pick: the user message stands alone (stock parity).
    if (order.len == 0) {
        clearTarget();
        return true;
    }
    rot = rotation.Rotation.init(alloc, def.members, order) catch {
        clearTarget();
        return false;
    };
    grp_log.info("group rotation: {d} member(s) queued", .{rot.?.members.len});
    launchCurrent();
    return true;
}

/// Abort the rotation: the queue clears; a member mid-stream seals through the normal stop
/// path (char_api.stopStream calls this BEFORE cancelling the reader), a launch parked on its
/// deep card just ends here since it has no stream to seal.
pub fn cancel() void {
    if (rot == null) return;
    const r = &rot.?;
    r.stop();
    grp_log.info("group rotation: stopped, queue cleared", .{});
    if (pending_launch) finish();
}

/// Seal hook, called by char_api.persistNewTurns FIRST: true = this seal belonged to a group
/// rotation and was handled here (the solo path must not also append it).
pub fn sealCurrent() bool {
    if (rot == null) return false;
    const r = &rot.?;
    const m = r.current() orelse {
        finish();
        return true;
    };
    if (char_api.chatLoadSeq() != grp_seq) {
        grp_log.debug("group seal skipped: chat re-synced mid-rotation", .{});
        finish();
        return true;
    }
    const msgs = store.slice();
    // The rotation's member list is the attribution authority; the store's last body is the text.
    if (msgs.len > 0) appendGroupTurn(m.name, msgs[msgs.len - 1].body, false);
    if (r.advance() != null) launchCurrent() else finish();
    return true;
}

/// The JS pump's stream fetch failed before sealing (backend gone mid-rotation): no turn to
/// persist, nothing will call the seal hook, so the rotation must end here or it wedges.
pub fn onStreamFailed() void {
    if (rot == null) return;
    grp_log.warn("group rotation: stream failed, aborting the remaining queue", .{});
    finish();
}

/// Deep-card settle hook (char_api.onDeepCardDone, success and failure alike): a parked launch
/// proceeds with whatever card depth actually landed, after one retry for the cache-miss case
/// where a different card's fetch was in flight when we asked.
pub fn onDeepCardSettled() void {
    if (!pending_launch) return;
    if (rot == null) {
        pending_launch = false;
        return;
    }
    const r = &rot.?;
    const m = r.current() orelse {
        pending_launch = false;
        finish();
        return;
    };
    if (char_api.deepCardReady(m.avatar) or deep_tried) {
        pending_launch = false;
        fire(m);
        return;
    }
    deep_tried = true;
    if (char_api.requestDeepCard(m.avatar) == .unavailable) {
        pending_launch = false;
        fire(m);
    }
}

fn launchCurrent() void {
    if (rot == null) return;
    const r = &rot.?;
    const m = r.current() orelse {
        finish();
        return;
    };
    deep_tried = false;
    if (char_api.deepCardReady(m.avatar)) {
        fire(m);
        return;
    }
    if (char_api.requestDeepCard(m.avatar) == .unavailable) {
        fire(m);
        return;
    }
    pending_launch = true;
}

fn fire(m: rotation.Member) void {
    if (!char_api.launchGroupMember(m)) {
        grp_log.warn("group rotation: launch failed for {s}, aborting the remaining queue", .{m.name});
        finish();
    }
}

fn finish() void {
    if (rot) |*r| r.deinit();
    rot = null;
    pending_launch = false;
    clearTarget();
}

fn clearTarget() void {
    if (chat_id_buf.len > 0) {
        alloc.free(chat_id_buf);
        chat_id_buf = &.{};
    }
}

/// The user turn: into the display store under the persona's name+avatar, onto the screen, and
/// through the group append route, mirroring the solo sendMessage sequence.
fn appendUserTurn(text: []const u8) void {
    const persona = char_api.activePersona();
    const user_name = if (persona) |p| p.name else "You";
    const persona_avatar: ?[]u8 = if (persona) |p|
        (if (p.avatar.len > 0) data.thumbUrl(alloc, "persona", p.avatar) catch null else null)
    else
        null;
    defer if (persona_avatar) |u| alloc.free(u);
    store.global.appendCopy(user_name, text, persona_avatar orelse "") catch |err| {
        grp_log.err("group send: append user turn failed: {s}", .{@errorName(err)});
        return;
    };
    regions.bumpMessageLog();
    reader.pinBottom();
    appendGroupTurn(user_name, text, true);
}

/// Persist one turn to the group chat. Same route and message shape as the solo appendTurn;
/// the group_id addresses groupChats/<id>.jsonl via the server's ChatRef (invariant 5). No
/// change_token this cut: the group reader that would own the token is 3c-A's; appends are
/// whole-line adds under the server's file lock, so nothing truncates without one.
fn appendGroupTurn(name: []const u8, mes: []const u8, is_user: bool) void {
    if (chat_id_buf.len == 0) return;
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .group_id = chat_id_buf,
        .limit = pager.TAIL_LIMIT,
        .messages = .{
            .{
                .name = name,
                .is_user = is_user,
                .is_system = false,
                .send_date = @as(i64, @intFromFloat(char_api.nowMs())),
                .mes = mes,
                .extra = .{},
            },
        },
    }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/chats/append", body, @intFromBool(is_user), onGroupAppendDone, .{});
}

fn onGroupAppendDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const which: []const u8 = if (tag != 0) "user" else "member";
    if (status == 409) {
        // The group file changed underneath (another writer). No group re-sync path exists this
        // cut, so stop the queue; an in-flight member still seals through the normal path.
        grp_log.warn("group append ({s}): file changed (409), stopping the rotation", .{which});
        cancel();
        return;
    }
    if (status < 200 or status >= 300) {
        grp_log.warn("group append ({s}) failed: {d}, turn not persisted", .{ which, status });
        return;
    }
    grp_log.debug("group append ({s}) persisted", .{which});
}
