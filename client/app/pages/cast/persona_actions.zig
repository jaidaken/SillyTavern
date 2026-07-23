//! Persona data flows the persona panel drives: auto-select on load, and the persona CRUD. The
//! persona_store is the source of truth for the persona set; CRUD mutates it directly for instant UI,
//! then funnels persistence through reading_prefs.zig, which owns the SINGLE debounced settings
//! saver. This module never writes /api/settings/save itself: a second full-blob writer would race
//! and clobber reading_prefs's pending debounced write. reading_prefs.mergedSettings calls
//! mergePersonaState (below) to serialize this module's state into the blob it saves.
//!
//! No new server endpoint (HARD_RULE 3): personas/descriptions/user_avatar/default_persona persist
//! in the settings blob; avatars use the existing /api/avatars/upload (multipart, JS-forced) and
//! /api/avatars/delete (JSON). Auto-select precedence: root user_avatar, then power_user
//! .default_persona, then the first persona (all keyed by avatar filename).
//!
//! zx-importing, so browser-verified through the interaction gate (ZX5).

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const net = @import("../platform/net.zig");
const uploads = @import("../platform/uploads.zig");
const persona_store = @import("./persona_store.zig");
const reading_prefs = @import("../chat/reading_prefs.zig");
const regions = @import("../shell/regions.zig");
const notifications = @import("../notify/notifications.zig");

const alloc = persona_store.page_gpa;
const log = std.log.scoped(.personas);

// The default persona (power_user.default_persona) as an avatar filename; empty = none. The store
// holds the personas + descriptions + the current selection, but not the default, so it lives here.
var default_avatar: []u8 = &.{};

// Guards mergePersonaState: writing the persona set from an unloaded (empty) store would wipe the
// account's personas, so persona keys stay untouched until a real load or CRUD sets this.
var authoritative: bool = false;

fn setOwned(dst: *[]u8, src: []const u8) void {
    if (dst.len > 0) alloc.free(dst.*);
    dst.* = alloc.dupe(u8, src) catch &.{};
}

// ---- auto-select + remember-last -------------------------------------------------------------

/// Set the store's selected index from a fresh settings blob by precedence, capture the default, and
/// mark the store authoritative. Called by char_api after it fills the persona store, so a reload
/// lands on the account's last-used persona (persisted as user_avatar) and re-writes the default.
pub fn applyAutoSelect(settings_str: []const u8) void {
    authoritative = true;
    captureDefault(settings_str);
    const personas = persona_store.slice();
    if (personas.len == 0) return;
    persona_store.select(pickIndex(settings_str, personas));
}

fn captureDefault(settings_str: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, settings_str, .{}) catch return;
    const root_obj = switch (root) {
        .object => |o| o,
        else => return,
    };
    if (root_obj.get("power_user")) |pu| switch (pu) {
        .object => |puo| {
            if (stringField(puo, "default_persona")) |dp| setOwned(&default_avatar, dp);
        },
        else => {},
    };
}

/// Precedence match of the blob's user_avatar then power_user.default_persona against the loaded
/// avatar filenames; the first persona when neither key names a loaded one (so a selection is always
/// visible). A malformed or non-object blob degrades to the first persona.
fn pickIndex(settings_str: []const u8, personas: []const persona_store.Persona) usize {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, settings_str, .{}) catch return 0;
    const root_obj = switch (root) {
        .object => |o| o,
        else => return 0,
    };
    if (stringField(root_obj, "user_avatar")) |ua| {
        if (indexOfAvatar(personas, ua)) |i| return i;
    }
    if (root_obj.get("power_user")) |pu| switch (pu) {
        .object => |puo| {
            if (stringField(puo, "default_persona")) |dp| {
                if (indexOfAvatar(personas, dp)) |i| return i;
            }
        },
        else => {},
    };
    return 0;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn indexOfAvatar(personas: []const persona_store.Persona, avatar: []const u8) ?usize {
    for (personas, 0..) |p, i| {
        if (std.mem.eql(u8, p.avatar, avatar)) return i;
    }
    return null;
}

// ---- serialize into the single saver's blob ---------------------------------------------------

/// Write the persona state (user_avatar, personas, persona_descriptions, default_persona) into the
/// settings object reading_prefs is about to save. Called from reading_prefs.mergedSettings on every
/// save. Skips entirely until the store is authoritative, so a save can never wipe the account's
/// personas with an unloaded store. Descriptions are written as plain strings, which is what the
/// client's extractPersonas reads; real SillyTavern stores persona_descriptions as objects, a
/// divergence flagged to the lead. The whole persona set is written from the store, so a concurrent
/// external change to personas is overwritten (single-user, single-frontend model).
pub fn mergePersonaState(a: std.mem.Allocator, root_obj: *std.json.ObjectMap) !void {
    if (!authoritative) return;
    if (persona_store.selected()) |sel| {
        try root_obj.put(a, "user_avatar", .{ .string = try a.dupe(u8, sel.avatar) });
    }
    const pu = try ensureObject(a, root_obj, "power_user");
    var personas: std.json.ObjectMap = .empty;
    var descs: std.json.ObjectMap = .empty;
    for (persona_store.slice()) |p| {
        try personas.put(a, try a.dupe(u8, p.avatar), .{ .string = try a.dupe(u8, p.name) });
        try descs.put(a, try a.dupe(u8, p.avatar), .{ .string = try a.dupe(u8, p.description) });
    }
    try pu.put(a, "personas", .{ .object = personas });
    try pu.put(a, "persona_descriptions", .{ .object = descs });
    if (default_avatar.len > 0) {
        try pu.put(a, "default_persona", .{ .string = try a.dupe(u8, default_avatar) });
    }
}

fn ensureObject(a: std.mem.Allocator, parent: *std.json.ObjectMap, key: []const u8) !*std.json.ObjectMap {
    if (parent.getPtr(key)) |v| {
        switch (v.*) {
            .object => return &v.object,
            else => {
                v.* = .{ .object = .empty };
                return &v.object;
            },
        }
    }
    try parent.put(a, try a.dupe(u8, key), .{ .object = .empty });
    return &parent.getPtr(key).?.object;
}

// ---- public entries (mutate the store, then flush through the single saver) --------------------

/// Persist the current selection (remember-last). The selection already stands in the store; this
/// only schedules the debounced save, which writes it back as user_avatar.
pub fn persistSelection() void {
    if (zx.platform.role != .client) return;
    reading_prefs.scheduleSave();
}

/// Mark the selected persona as the account default (power_user.default_persona).
pub fn setDefault(avatar: []const u8) void {
    if (zx.platform.role != .client) return;
    setOwned(&default_avatar, avatar);
    reading_prefs.scheduleSave();
    regions.bumpShell();
}

/// New persona: prompt a name, mint an avatar filename (its image is added later via replaceAvatar),
/// append it to the store. Cancel or an empty name aborts.
pub fn addPersona() void {
    if (zx.platform.role != .client) return;
    const name = promptString("New persona name:", "") orelse return;
    defer alloc.free(name);
    var buf: [32]u8 = undefined;
    const filename = std.fmt.bufPrint(&buf, "{d}.png", .{@as(i64, @intFromFloat(nowMs()))}) catch return;
    addToStore(filename, name, "");
    authoritative = true;
    reading_prefs.scheduleSave();
    regions.bumpShell();
}

pub fn renamePersona(avatar: []const u8, current_name: []const u8) void {
    if (zx.platform.role != .client) return;
    const name = promptString("Rename persona:", current_name) orelse return;
    defer alloc.free(name);
    if (std.mem.eql(u8, name, current_name)) return;
    setField(avatar, .name, name);
    reading_prefs.scheduleSave();
    regions.bumpShell();
}

pub fn editDescription(avatar: []const u8, current_desc: []const u8) void {
    if (zx.platform.role != .client) return;
    const desc = promptString("Persona description:", current_desc) orelse return;
    defer alloc.free(desc);
    setField(avatar, .description, desc);
    reading_prefs.scheduleSave();
    regions.bumpShell();
}

/// Delete a persona: remove its avatar file (JSON /api/avatars/delete, best-effort; a 404 is fine
/// for a persona that never got an image), drop it from the store, and clear the default if it
/// pointed here. The store change flushes through the saver.
pub fn deletePersona(avatar: []const u8, name: []const u8) void {
    if (zx.platform.role != .client) return;
    const msg = std.fmt.allocPrint(alloc, "Delete persona \"{s}\"? This cannot be undone.", .{name}) catch return;
    defer alloc.free(msg);
    if (!confirmDialog(msg)) return;
    if (std.json.Stringify.valueAlloc(alloc, .{ .avatar = avatar }, .{})) |body| {
        defer alloc.free(body);
        net.request("/api/avatars/delete", body, 0, onAvatarDeleted, .{});
    } else |_| {}
    if (default_avatar.len > 0 and std.mem.eql(u8, default_avatar, avatar)) {
        alloc.free(default_avatar);
        default_avatar = &.{};
    }
    removeFromStore(avatar);
    reading_prefs.scheduleSave();
    regions.bumpShell();
}

fn onAvatarDeleted(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (status != 404 and (status < 200 or status >= 300)) {
        log.warn("persona delete: avatar delete {d}, the settings entry is removed regardless", .{status});
    }
}

/// Replace the selected persona's avatar image (multipart upload, avatar file + overwrite_name).
/// uploads.zig reads #persona-avatar-input to bytes and builds the multipart in Zig; onAvatarUploaded
/// re-renders on success.
pub fn replaceAvatar(avatar: []const u8) void {
    if (zx.platform.role != .client) return;
    const fields = [_]uploads.Field{.{ .name = "overwrite_name", .value = avatar }};
    uploads.start(.{
        .input_id = "persona-avatar-input",
        .url = "/api/avatars/upload",
        .fields = &fields,
        .on_done = onAvatarUploaded,
    });
}

/// uploads.zig's settle callback. On success re-render so the new thumbnail shows (the filename, hence
/// the img src, is unchanged; the server busts its own thumbnail cache on overwrite).
fn onAvatarUploaded(status: u16, sent: bool) void {
    if (zx.platform.role != .client) return;
    if (!sent) return;
    if (status >= 200 and status < 300) {
        notifications.push(.success, "Persona avatar updated", notifications.default_ttl_ms);
        regions.bumpShell();
    } else {
        log.warn("persona avatar upload failed: {d}", .{status});
        notifications.pushFmt(.err, notifications.error_ttl_ms, "Persona avatar upload failed: {d}", .{status});
    }
}

// ---- store mutation (persona_store is the source of truth) ------------------------------------

const Field = enum { name, description };

fn setField(avatar: []const u8, field: Field, value: []const u8) void {
    for (persona_store.global.personas.items) |*p| {
        if (!std.mem.eql(u8, p.avatar, avatar)) continue;
        const dup = alloc.dupe(u8, value) catch return;
        switch (field) {
            .name => {
                if (p.name_owned) |o| alloc.free(o);
                p.name = dup;
                p.name_owned = dup;
            },
            .description => {
                if (p.description_owned) |o| alloc.free(o);
                p.description = dup;
                p.description_owned = dup;
            },
        }
        return;
    }
}

fn addToStore(filename: []const u8, name: []const u8, desc: []const u8) void {
    const a_ = alloc.dupe(u8, filename) catch return;
    const n_ = alloc.dupe(u8, name) catch {
        alloc.free(a_);
        return;
    };
    const d_ = alloc.dupe(u8, desc) catch {
        alloc.free(a_);
        alloc.free(n_);
        return;
    };
    persona_store.global.append(.{
        .name = n_,
        .avatar = a_,
        .description = d_,
        .name_owned = n_,
        .avatar_owned = a_,
        .description_owned = d_,
    }) catch {
        alloc.free(a_);
        alloc.free(n_);
        alloc.free(d_);
    };
}

fn removeFromStore(avatar: []const u8) void {
    var i: usize = 0;
    while (i < persona_store.global.personas.items.len) : (i += 1) {
        if (!std.mem.eql(u8, persona_store.global.personas.items[i].avatar, avatar)) continue;
        const removed = persona_store.global.personas.orderedRemove(i);
        if (removed.name_owned) |o| alloc.free(o);
        if (removed.avatar_owned) |o| alloc.free(o);
        if (removed.description_owned) |o| alloc.free(o);
        if (persona_store.global.selected_index) |s| {
            if (s == i) {
                persona_store.global.selected_index = if (persona_store.global.personas.items.len > 0) 0 else null;
            } else if (s > i) {
                persona_store.global.selected_index = s - 1;
            }
        }
        return;
    }
}

// ---- dialogs (jsz reflection, mirroring char_api) ---------------------------------------------

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

fn nowMs() f64 {
    if (zx.platform.role != .client) return 0;
    const date_ctor = js.global.get(js.Object, "Date") catch return 0;
    defer date_ctor.deinit();
    return date_ctor.call(f64, "now", .{}) catch 0;
}
