//! Group roster data flows (w3-grp): the /api/groups fetch and the CRUD the roster panel drives.
//! The pure model lives in group_store.zig (zx-free, unit-tested); this owns the network, the
//! dialogs, and the render bump, mirroring backgrounds.zig's shape (load states, ptr-tagged
//! mutations, server-authoritative deletes).
//!
//! Persistence model: an EDIT mutates the store first (instant UI), then posts the whole patched
//! group file to /api/groups/edit; a refused write reports and re-fetches the roster so the panel
//! returns to server truth rather than showing an edit that never landed. A DELETE is
//! server-authoritative the whole way (the row leaves only after a 2xx), because delete also
//! removes the group's chat files and a lie there is unrecoverable. CREATE stages a local draft
//! (group_store id ""), posts once on commit, and adopts the server's minted group from the
//! response.
//!
//! zx-importing, so browser-verified through the interaction gate (ZX5).

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const gs = @import("./group_store.zig");
const net = @import("./net.zig");
const regions = @import("./regions.zig");

const alloc = gs.page_gpa;
const log = std.log.scoped(.groups);

/// The four states every async surface designs (WD54). `idle` has not asked yet: the roster loads
/// when its panel first opens, not at boot.
pub const LoadState = enum { idle, loading, ready, failed };

var load_state: LoadState = .idle;
var last_error: []u8 = &.{};
var create_pending: bool = false;

/// The panel's render handle, published on its first render; this module is its only bumper.
pub var region: ?*zx.State(u32) = null;

fn bump() void {
    if (region) |h| h.set(h.get() +% 1);
}

/// The panel's own view-state changes (open/close the editor) ride the same region bump.
pub fn bumpPanel() void {
    bump();
}

pub fn state() LoadState {
    return load_state;
}

pub fn errorText() []const u8 {
    return last_error;
}

pub fn createPending() bool {
    return create_pending;
}

// ---- the roster fetch --------------------------------------------------------------------------

/// Load the roster once, on the panel's first render. Idempotent while loading or after success.
pub fn ensureLoaded() void {
    if (zx.platform.role != .client) return;
    if (load_state != .idle) return;
    load_state = .loading;
    net.request("/api/groups/all", "{}", 0, onList, .{});
}

/// Re-fetch: the retry the error state offers, and the resync after a refused edit.
pub fn reload() void {
    if (zx.platform.role != .client) return;
    if (load_state == .loading) return;
    clearError();
    load_state = .loading;
    bump();
    net.request("/api/groups/all", "{}", 0, onList, .{});
}

fn onList(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (res == null or status < 200 or status >= 300) {
        load_state = .failed;
        setError("The groups could not be loaded ({d}).", .{status});
        bump();
        return;
    }
    const parsed = res.?.json(std.json.Value) catch {
        load_state = .failed;
        setError("The groups list came back in a shape this client does not read.", .{});
        bump();
        return;
    };
    defer parsed.deinit();
    gs.global.replaceAll(parsed.value) catch {
        load_state = .failed;
        setError("The groups list did not fit in memory.", .{});
        bump();
        return;
    };
    load_state = .ready;
    clearError();
    log.debug("groups loaded: {d}", .{gs.slice().len});
    resolvePendingOpen();
    // Foreign surfaces read the roster too (the characters-panel quick list, home's group rows),
    // and their regions know nothing of this fetch: bump them so names and avatars resolve.
    regions.bumpCharacterList();
    regions.bumpHome();
    bump();
}

// ---- open (the send target) --------------------------------------------------------------------

/// Row activation: make this group the open one and hand off to the send/load side when it has
/// registered (gs.on_group_open). A draft only selects (there is no chat to open yet).
pub fn openGroup(index: usize) void {
    if (zx.platform.role != .client) return;
    gs.select(index);
    if (gs.activeGroupId() != null) {
        if (gs.on_group_open) |f| f(index);
    }
    bump();
}

/// The one open still pending a roster load, as a group id. A home row can ask for a group before
/// /api/groups/all ever ran; the id parks here and onList resolves it.
var pending_open: []u8 = &.{};

/// Open a group by id from a surface that does not hold the roster (home's recent rows). Loaded and
/// known -> opens now. Not loaded yet -> parks the id and fires the fetch; the load callback opens
/// it. A loaded roster that does NOT contain the id drops the ask with a log line (a stale recent
/// row for a deleted group must not wedge a pending open).
pub fn openGroupById(id: []const u8) void {
    if (zx.platform.role != .client) return;
    if (id.len == 0) return;
    if (gs.global.indexOfId(id)) |i| {
        clearPendingOpen();
        openGroup(i);
        return;
    }
    if (load_state == .ready) {
        log.warn("open group {s}: not in the loaded roster (deleted?)", .{id});
        return;
    }
    setPendingOpen(id);
    if (load_state == .idle) {
        ensureLoaded();
    } else if (load_state == .failed) {
        reload();
    }
}

fn resolvePendingOpen() void {
    if (pending_open.len == 0) return;
    if (gs.global.indexOfId(pending_open)) |i| {
        openGroup(i);
    } else {
        log.warn("open group {s}: not in the loaded roster (deleted?)", .{pending_open});
    }
    clearPendingOpen();
}

fn setPendingOpen(id: []const u8) void {
    const dup = alloc.dupe(u8, id) catch return;
    clearPendingOpen();
    pending_open = dup;
}

fn clearPendingOpen() void {
    if (pending_open.len == 0) return;
    alloc.free(pending_open);
    pending_open = &.{};
}

// ---- create (draft -> commit) ------------------------------------------------------------------

/// New group: prompt a name and stage a local draft the editor then fills. One draft at a time; a
/// second New jumps to the existing draft instead of stacking another.
pub fn startCreate() void {
    if (zx.platform.role != .client) return;
    if (draftIndex()) |i| {
        gs.openEditor(i);
        bump();
        return;
    }
    const name = promptString("New group name:", "") orelse return;
    defer alloc.free(name);
    const i = gs.global.appendDraft(name) catch {
        setError("The group could not be created: the client is out of memory.", .{});
        bump();
        return;
    };
    gs.openEditor(i);
    bump();
}

/// Commit the draft: one /api/groups/create with the picked roster; the server mints id/chat_id and
/// echoes the group back, which replaces the draft. Members are required: a group with nobody in it
/// cannot activate anyone.
pub fn commitCreate() void {
    if (zx.platform.role != .client) return;
    if (create_pending) return;
    const i = draftIndex() orelse return;
    const g = &gs.global.groups.items[i];
    if (g.members.items.len == 0) {
        setError("Add at least one member before creating the group.", .{});
        bump();
        return;
    }
    const body = gs.buildCreatePayload(alloc, g) catch {
        setError("The group could not be created: the client is out of memory.", .{});
        bump();
        return;
    };
    defer alloc.free(body);
    create_pending = true;
    bump();
    net.request("/api/groups/create", body, 0, onCreated, .{});
}

fn onCreated(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    create_pending = false;
    if (res == null or status < 200 or status >= 300) {
        setError("The group could not be created ({d}). Nothing was saved.", .{status});
        bump();
        return;
    }
    const i = draftIndex() orelse {
        bump();
        return;
    };
    const body = res.?.text() catch {
        // Created server-side but the response is unreadable: re-fetch rather than guess.
        reload();
        return;
    };
    const ok = gs.global.promoteDraft(i, body) catch false;
    if (!ok) {
        reload();
        return;
    }
    clearError();
    log.debug("group created: {s}", .{gs.slice()[i].id});
    bump();
}

/// Abandon the draft. Local-only, nothing to tell the server.
pub fn cancelCreate() void {
    if (zx.platform.role != .client) return;
    const i = draftIndex() orelse return;
    gs.removeGroupAt(i);
    bump();
}

fn draftIndex() ?usize {
    for (gs.slice(), 0..) |g, i| {
        if (g.id.len == 0) return i;
    }
    return null;
}

// ---- edit (mutate locally, persist the whole patched file) -------------------------------------

/// One in-flight edit, addressed by group id so the callback survives a roster reorder. The name
/// rides along for the error message.
const Mutation = struct {
    id: []u8,
    name: []u8,
};

fn startMutation(id: []const u8, name: []const u8) ?*Mutation {
    const m = alloc.create(Mutation) catch return null;
    const id_c = alloc.dupe(u8, id) catch {
        alloc.destroy(m);
        return null;
    };
    const name_c = alloc.dupe(u8, name) catch {
        alloc.free(id_c);
        alloc.destroy(m);
        return null;
    };
    m.* = .{ .id = id_c, .name = name_c };
    return m;
}

/// Same invariant as backgrounds.zig mutationFor: net.zig returns the tag untouched on every path,
/// so the only tag reaching here is one startMutation minted.
fn mutationFor(tag: u64) *Mutation {
    return @ptrFromInt(@as(usize, @intCast(tag)));
}

fn endMutation(m: *Mutation) void {
    alloc.free(m.id);
    alloc.free(m.name);
    alloc.destroy(m);
}

/// Persist the group at `index` as it now stands in the store. A draft skips the wire: its state
/// goes out with commitCreate instead.
fn persistEdit(index: usize) void {
    if (index >= gs.slice().len) return;
    const g = &gs.global.groups.items[index];
    if (g.isDraft()) return;
    const body = gs.buildEditPayload(alloc, g) catch {
        setError("\"{s}\" could not be saved: the client is out of memory.", .{g.name});
        bump();
        return;
    };
    defer alloc.free(body);
    const m = startMutation(g.id, g.name) orelse {
        setError("\"{s}\" could not be saved: the client is out of memory.", .{g.name});
        bump();
        return;
    };
    net.request("/api/groups/edit", body, @intFromPtr(m), onEdited, .{});
}

fn onEdited(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const m = mutationFor(tag);
    defer endMutation(m);
    if (status < 200 or status >= 300) {
        // The store carries an edit the server refused: re-fetch so the panel shows server truth.
        setError("\"{s}\" could not be saved ({d}). Showing the server's version.", .{ m.name, status });
        reload();
        return;
    }
    clearError();
}

// ---- the editor's mutation entries (store first, then persist) ---------------------------------

pub fn renameGroup(index: usize) void {
    if (zx.platform.role != .client) return;
    if (index >= gs.slice().len) return;
    const current = gs.slice()[index].name;
    const name = promptString("Rename group:", current) orelse return;
    defer alloc.free(name);
    if (std.mem.eql(u8, name, current)) return;
    gs.global.rename(index, name) catch return;
    persistEdit(index);
    bump();
}

pub fn addMember(index: usize, avatar: []const u8) void {
    if (zx.platform.role != .client) return;
    gs.global.addMember(index, avatar) catch return;
    persistEdit(index);
    bump();
}

pub fn removeMember(index: usize, avatar: []const u8) void {
    if (zx.platform.role != .client) return;
    gs.global.removeMember(index, avatar);
    persistEdit(index);
    bump();
}

pub fn moveMember(index: usize, from: usize, to: usize) void {
    if (zx.platform.role != .client) return;
    gs.global.moveMember(index, from, to);
    persistEdit(index);
    bump();
}

pub fn toggleMute(index: usize, avatar: []const u8) void {
    if (zx.platform.role != .client) return;
    if (index >= gs.slice().len) return;
    const muted = gs.isMuted(&gs.global.groups.items[index], avatar);
    gs.global.setMuted(index, avatar, !muted) catch return;
    persistEdit(index);
    bump();
}

pub fn setStrategyFromStr(value: []const u8) void {
    if (zx.platform.role != .client) return;
    const i = gs.editing_index orelse return;
    const s: gs.ActivationStrategy = if (std.mem.eql(u8, value, "natural"))
        .natural
    else if (std.mem.eql(u8, value, "list"))
        .list
    else if (std.mem.eql(u8, value, "manual"))
        .manual
    else if (std.mem.eql(u8, value, "pooled"))
        .pooled
    else
        return;
    gs.global.setStrategy(i, s);
    persistEdit(i);
    bump();
}

pub fn setModeFromStr(value: []const u8) void {
    if (zx.platform.role != .client) return;
    const i = gs.editing_index orelse return;
    const m: gs.GenerationMode = if (std.mem.eql(u8, value, "swap"))
        .swap
    else if (std.mem.eql(u8, value, "append"))
        .append
    else if (std.mem.eql(u8, value, "append_disabled"))
        .append_disabled
    else
        return;
    gs.global.setMode(i, m);
    persistEdit(i);
    bump();
}

pub fn toggleAllowSelf(index: usize) void {
    if (zx.platform.role != .client) return;
    if (index >= gs.slice().len) return;
    gs.global.setAllowSelf(index, !gs.slice()[index].allow_self_responses);
    persistEdit(index);
    bump();
}

// ---- delete (server-authoritative) -------------------------------------------------------------

/// Delete a group. The server also deletes the group's own chat files (groupChats/<id>.jsonl);
/// member characters and their solo chats are untouched, and the confirm says exactly that so the
/// scope of the loss is stated before it happens.
pub fn deleteGroup(index: usize) void {
    if (zx.platform.role != .client) return;
    if (index >= gs.slice().len) return;
    const g = gs.slice()[index];
    if (g.id.len == 0) {
        cancelCreate();
        return;
    }
    const msg = std.fmt.allocPrint(
        alloc,
        "Delete group \"{s}\" and its group chats? The member characters and their own chats are not touched. This cannot be undone.",
        .{g.name},
    ) catch return;
    defer alloc.free(msg);
    if (!confirmDialog(msg)) return;

    const body = std.json.Stringify.valueAlloc(alloc, .{ .id = g.id }, .{}) catch return;
    defer alloc.free(body);
    const m = startMutation(g.id, g.name) orelse {
        setError("\"{s}\" could not be deleted: the client is out of memory.", .{g.name});
        bump();
        return;
    };
    net.request("/api/groups/delete", body, @intFromPtr(m), onDeleted, .{});
}

fn onDeleted(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const m = mutationFor(tag);
    defer endMutation(m);
    if (status < 200 or status >= 300) {
        setError("\"{s}\" could not be deleted ({d}). It is still on the server.", .{ m.name, status });
        bump();
        return;
    }
    // Re-find by id: the roster may have shifted while the request was in flight.
    if (gs.global.indexOfId(m.id)) |i| {
        gs.removeGroupAt(i);
    }
    clearError();
    bump();
}

// ---- error surface + dialogs (jsz reflection, mirroring backgrounds.zig) -----------------------

fn setError(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch return;
    if (last_error.len > 0) alloc.free(last_error);
    last_error = msg;
    log.warn("{s}", .{msg});
}

fn clearError() void {
    if (last_error.len == 0) return;
    alloc.free(last_error);
    last_error = &.{};
}

fn promptString(msg: []const u8, default_value: []const u8) ?[]u8 {
    if (zx.platform.role != .client) return null;
    const out = js.global.callAlloc(?js.String, alloc, "prompt", .{ js.string(msg), js.string(default_value) }) catch return null;
    const s = out orelse return null;
    if (s.len == 0) {
        alloc.free(s);
        return null;
    }
    return s;
}

fn confirmDialog(msg: []const u8) bool {
    if (zx.platform.role != .client) return false;
    return js.global.call(bool, "confirm", .{js.string(msg)}) catch false;
}
