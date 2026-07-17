//! Pure model for group chats (w3-grp): the /api/groups wire contract, the roster store, the
//! membership mutations the panel drives, and the read surface the group send loop consumes. No zx
//! import, so the whole module runs under `zig build test` (ZX5 split); the fetch and DOM halves
//! live in group_actions.zig and the panel .zx, browser-verified through the interaction gate.
//!
//! Ownership: every string in a Group is duped into the store allocator and freed unconditionally
//! (no *_owned split: unlike characters, groups have no fixture/static source to borrow from).
//! Group copies returned by `selected()` borrow the store's memory; a roster reload or CRUD
//! invalidates them, so consumers read per-turn or dupe what they keep (same contract as
//! character_store).
//!
//! Edits round-trip through `raw`, the group's own JSON as the server sent it: /api/groups/edit
//! replaces the whole file with the request body, so a payload built only from modeled fields would
//! silently drop any key this client does not know (extension metadata, future upstream fields).
//! buildEditPayload patches the modeled keys into the raw object instead (invariant 1: no format
//! change, nothing dropped).

const std = @import("std");
const builtin = @import("builtin");

const character_store = @import("./character_store.zig");
const data = @import("./char_data.zig");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.groups);

/// group-chats.js group_activation_strategy. Non-exhaustive: a hand-edited file's unknown int is
/// preserved rather than corrupting the enum (and survives an edit round-trip via raw).
pub const ActivationStrategy = enum(u8) { natural = 0, list = 1, manual = 2, pooled = 3, _ };

/// group-chats.js group_generation_mode.
pub const GenerationMode = enum(u8) { swap = 0, append = 1, append_disabled = 2, _ };

/// One group as /api/groups/all returns it (groups.js /create field set + the stat-derived
/// date_last_chat). `id` "" marks a local draft not yet created server-side.
pub const Group = struct {
    id: []const u8,
    name: []const u8,
    avatar_url: []const u8,
    /// The active group chat: groupChats/<chat_id>.jsonl, the append/send target.
    chat_id: []const u8,
    /// Character avatar filenames; array order IS the list-strategy activation order.
    members: std.ArrayList([]const u8) = .empty,
    /// Muted members (server field disabled_members), avatar filenames.
    disabled: std.ArrayList([]const u8) = .empty,
    activation_strategy: ActivationStrategy = .natural,
    generation_mode: GenerationMode = .swap,
    allow_self_responses: bool = false,
    fav: bool = false,
    date_last_chat: u64 = 0,
    /// The entry's JSON as fetched (edit round-trip base). Empty for a draft.
    raw: []const u8,

    pub fn memberSlice(self: *const Group) []const []const u8 {
        return self.members.items;
    }

    pub fn mutedSlice(self: *const Group) []const []const u8 {
        return self.disabled.items;
    }

    pub fn isDraft(self: *const Group) bool {
        return self.id.len == 0;
    }
};

pub const GroupStore = struct {
    allocator: Allocator,
    groups: std.ArrayList(Group) = .empty,
    selected_index: ?usize = null,

    pub fn init(allocator: Allocator) GroupStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GroupStore) void {
        for (self.groups.items) |*g| self.freeGroup(g);
        self.groups.deinit(self.allocator);
        self.* = undefined;
    }

    fn freeGroup(self: *GroupStore, g: *Group) void {
        freeGroupIn(self.allocator, g);
    }

    fn freeGroupIn(a: Allocator, g: *Group) void {
        a.free(g.id);
        a.free(g.name);
        a.free(g.avatar_url);
        a.free(g.chat_id);
        a.free(g.raw);
        for (g.members.items) |m| a.free(m);
        g.members.deinit(a);
        for (g.disabled.items) |m| a.free(m);
        g.disabled.deinit(a);
    }

    pub fn slice(self: *const GroupStore) []const Group {
        return self.groups.items;
    }

    pub fn selected(self: *const GroupStore) ?Group {
        const i = self.selected_index orelse return null;
        if (i >= self.groups.items.len) return null;
        return self.groups.items[i];
    }

    pub fn select(self: *GroupStore, index: usize) void {
        self.selected_index = if (index < self.groups.items.len) index else null;
        log.debug("group select: {d} -> {?d}", .{ index, self.selected_index });
    }

    pub fn deselect(self: *GroupStore) void {
        self.selected_index = null;
    }

    pub fn indexOfId(self: *const GroupStore, id: []const u8) ?usize {
        if (id.len == 0) return null;
        for (self.groups.items, 0..) |g, i| {
            if (std.mem.eql(u8, g.id, id)) return i;
        }
        return null;
    }

    pub fn byId(self: *const GroupStore, id: []const u8) ?*const Group {
        const i = self.indexOfId(id) orelse return null;
        return &self.groups.items[i];
    }

    /// Swap the roster for a freshly fetched /api/groups/all body. Per-entry tolerant: one
    /// malformed entry costs that entry, never the whole roster. Built aside and committed at the
    /// end, so a failure part-way leaves the previous roster intact. Selection is re-found by id
    /// (a reload must not silently retarget the send loop at a different group).
    pub fn replaceAll(self: *GroupStore, root: std.json.Value) Allocator.Error!void {
        const a = self.allocator;
        var next: std.ArrayList(Group) = .empty;
        errdefer {
            for (next.items) |*g| freeGroupIn(a, g);
            next.deinit(a);
        }
        switch (root) {
            .array => |arr| {
                try next.ensureTotalCapacityPrecise(a, arr.items.len);
                for (arr.items) |entry| {
                    const g = try extractGroup(a, entry) orelse continue;
                    next.appendAssumeCapacity(g);
                }
            },
            else => {},
        }
        const kept_id: ?[]u8 = if (self.selected()) |sel|
            (if (sel.id.len > 0) try a.dupe(u8, sel.id) else null)
        else
            null;
        defer if (kept_id) |k| a.free(k);
        for (self.groups.items) |*g| self.freeGroup(g);
        self.groups.deinit(a);
        self.groups = next;
        self.selected_index = if (kept_id) |k| self.indexOfId(k) else null;
    }

    /// Append a local draft (id "", nothing server-side yet). The editor mutates it like any group;
    /// buildCreatePayload turns it into the /create body and promoteDraft adopts the response.
    pub fn appendDraft(self: *GroupStore, name: []const u8) Allocator.Error!usize {
        const a = self.allocator;
        const g = Group{
            .id = try a.dupe(u8, ""),
            .name = try a.dupe(u8, name),
            .avatar_url = try a.dupe(u8, ""),
            .chat_id = try a.dupe(u8, ""),
            .raw = try a.dupe(u8, ""),
        };
        errdefer {
            a.free(g.id);
            a.free(g.name);
            a.free(g.avatar_url);
            a.free(g.chat_id);
            a.free(g.raw);
        }
        try self.groups.append(a, g);
        return self.groups.items.len - 1;
    }

    /// Replace the draft at `index` with the group the /create response describes. On a parse
    /// failure the draft stays (false), so the user's picked roster is never dropped on a bad
    /// response.
    pub fn promoteDraft(self: *GroupStore, index: usize, body: []const u8) Allocator.Error!bool {
        if (index >= self.groups.items.len) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch return false;
        const g = try extractGroup(self.allocator, root) orelse return false;
        self.freeGroup(&self.groups.items[index]);
        self.groups.items[index] = g;
        return true;
    }

    /// Drop the group at `index`, keeping selection pinned to the group it pointed at.
    pub fn removeAt(self: *GroupStore, index: usize) void {
        if (index >= self.groups.items.len) return;
        var gone = self.groups.orderedRemove(index);
        self.freeGroup(&gone);
        if (self.selected_index) |s| {
            if (s == index) {
                self.selected_index = null;
            } else if (s > index) {
                self.selected_index = s - 1;
            }
        }
    }

    pub fn rename(self: *GroupStore, index: usize, name: []const u8) Allocator.Error!void {
        if (index >= self.groups.items.len) return;
        const g = &self.groups.items[index];
        const dup = try self.allocator.dupe(u8, name);
        self.allocator.free(g.name);
        g.name = dup;
    }

    /// Add a member (avatar filename). A duplicate is a no-op: the server model treats members as a
    /// set with order.
    pub fn addMember(self: *GroupStore, index: usize, avatar: []const u8) Allocator.Error!void {
        if (index >= self.groups.items.len) return;
        if (avatar.len == 0) return;
        const g = &self.groups.items[index];
        if (indexOfString(g.members.items, avatar) != null) return;
        const dup = try self.allocator.dupe(u8, avatar);
        errdefer self.allocator.free(dup);
        try g.members.append(self.allocator, dup);
    }

    /// Remove a member and any mute entry it holds (a mute for a non-member is dead data the
    /// server would faithfully persist).
    pub fn removeMember(self: *GroupStore, index: usize, avatar: []const u8) void {
        if (index >= self.groups.items.len) return;
        const g = &self.groups.items[index];
        if (indexOfString(g.members.items, avatar)) |i| {
            const gone = g.members.orderedRemove(i);
            self.allocator.free(gone);
        }
        if (indexOfString(g.disabled.items, avatar)) |i| {
            const gone = g.disabled.orderedRemove(i);
            self.allocator.free(gone);
        }
    }

    /// Reorder: move the member at `from` to sit at `to` (both indices into the members array).
    pub fn moveMember(self: *GroupStore, index: usize, from: usize, to: usize) void {
        if (index >= self.groups.items.len) return;
        const g = &self.groups.items[index];
        const n = g.members.items.len;
        if (from >= n or to >= n or from == to) return;
        const moved = g.members.orderedRemove(from);
        g.members.insertAssumeCapacity(to, moved);
    }

    pub fn setMuted(self: *GroupStore, index: usize, avatar: []const u8, muted: bool) Allocator.Error!void {
        if (index >= self.groups.items.len) return;
        const g = &self.groups.items[index];
        if (indexOfString(g.members.items, avatar) == null) return;
        const at = indexOfString(g.disabled.items, avatar);
        if (muted and at == null) {
            const dup = try self.allocator.dupe(u8, avatar);
            errdefer self.allocator.free(dup);
            try g.disabled.append(self.allocator, dup);
        } else if (!muted and at != null) {
            const gone = g.disabled.orderedRemove(at.?);
            self.allocator.free(gone);
        }
    }

    pub fn setStrategy(self: *GroupStore, index: usize, s: ActivationStrategy) void {
        if (index >= self.groups.items.len) return;
        self.groups.items[index].activation_strategy = s;
    }

    pub fn setMode(self: *GroupStore, index: usize, m: GenerationMode) void {
        if (index >= self.groups.items.len) return;
        self.groups.items[index].generation_mode = m;
    }

    pub fn setAllowSelf(self: *GroupStore, index: usize, v: bool) void {
        if (index >= self.groups.items.len) return;
        self.groups.items[index].allow_self_responses = v;
    }
};

fn indexOfString(items: []const []const u8, needle: []const u8) ?usize {
    for (items, 0..) |s, i| {
        if (std.mem.eql(u8, s, needle)) return i;
    }
    return null;
}

// ---- wire parse (per-entry tolerant) ----------------------------------------------------------

/// One /all entry -> an owned Group, or null when the entry is unusable (not an object, or no id
/// that can name the file to edit/delete). A numeric id (hand-edited file) is rendered to its
/// decimal string, which is exactly what path.join would have received.
fn extractGroup(a: Allocator, v: std.json.Value) Allocator.Error!?Group {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const id = try idString(a, obj) orelse return null;
    errdefer a.free(id);
    const name = try a.dupe(u8, stringOf(obj, "name") orelse "");
    errdefer a.free(name);
    const avatar_url = try a.dupe(u8, stringOf(obj, "avatar_url") orelse "");
    errdefer a.free(avatar_url);
    // chat_id defaults to the group id, the same fallback /create writes.
    const chat_id = try a.dupe(u8, stringOf(obj, "chat_id") orelse id);
    errdefer a.free(chat_id);
    const raw = std.json.Stringify.valueAlloc(a, v, .{}) catch return error.OutOfMemory;
    errdefer a.free(raw);

    var g = Group{
        .id = id,
        .name = name,
        .avatar_url = avatar_url,
        .chat_id = chat_id,
        .raw = raw,
        .activation_strategy = enumOf(ActivationStrategy, obj, "activation_strategy"),
        .generation_mode = enumOf(GenerationMode, obj, "generation_mode"),
        .allow_self_responses = boolOf(obj, "allow_self_responses"),
        .fav = favOf(obj),
        .date_last_chat = msOf(obj, "date_last_chat"),
    };
    errdefer {
        for (g.members.items) |m| a.free(m);
        g.members.deinit(a);
        for (g.disabled.items) |m| a.free(m);
        g.disabled.deinit(a);
    }
    try fillStrings(a, &g.members, obj, "members");
    try fillStrings(a, &g.disabled, obj, "disabled_members");
    return g;
}

fn fillStrings(a: Allocator, list: *std.ArrayList([]const u8), obj: std.json.ObjectMap, key: []const u8) Allocator.Error!void {
    const v = obj.get(key) orelse return;
    const arr = switch (v) {
        .array => |arr| arr,
        else => return,
    };
    for (arr.items) |item| {
        switch (item) {
            .string => |s| {
                if (s.len == 0) continue;
                const dup = try a.dupe(u8, s);
                errdefer a.free(dup);
                try list.append(a, dup);
            },
            else => {},
        }
    }
}

fn idString(a: Allocator, obj: std.json.ObjectMap) Allocator.Error!?[]const u8 {
    const v = obj.get("id") orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) try a.dupe(u8, s) else null,
        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        else => null,
    };
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn boolOf(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

/// fav is written untyped by /create (whatever the client sent, possibly absent); read it the way
/// char_data reads a character's fav so both surfaces agree on what counts.
fn favOf(obj: std.json.ObjectMap) bool {
    const v = obj.get("fav") orelse return false;
    return data.favTruthy(v);
}

fn intOf(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else null,
        else => null,
    };
}

/// A stat mtimeMs arrives as a float; anything unreadable or negative reads as epoch 0 (sorts last,
/// renders as no date), never a parse failure.
fn msOf(obj: std.json.ObjectMap, key: []const u8) u64 {
    const n = intOf(obj, key) orelse return 0;
    return if (n > 0) @intCast(n) else 0;
}

fn enumOf(comptime E: type, obj: std.json.ObjectMap, key: []const u8) E {
    const n = intOf(obj, key) orelse return @enumFromInt(0);
    if (n < 0 or n > std.math.maxInt(u8)) return @enumFromInt(0);
    return @enumFromInt(@as(u8, @intCast(n)));
}

// ---- request payloads (pure, testable) --------------------------------------------------------

const CreateBody = struct {
    name: []const u8,
    members: []const []const u8,
    disabled_members: []const []const u8,
    activation_strategy: u8,
    generation_mode: u8,
    allow_self_responses: bool,
    fav: bool,
};

/// The /api/groups/create body for a draft. The server mints id/chat_id/chats and echoes the full
/// group back (promoteDraft adopts it).
pub fn buildCreatePayload(a: Allocator, g: *const Group) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(a, CreateBody{
        .name = g.name,
        .members = g.members.items,
        .disabled_members = g.disabled.items,
        .activation_strategy = @intFromEnum(g.activation_strategy),
        .generation_mode = @intFromEnum(g.generation_mode),
        .allow_self_responses = g.allow_self_responses,
        .fav = g.fav,
    }, .{}) catch return error.OutOfMemory;
}

/// The /api/groups/edit body: the group's raw JSON with the modeled fields patched in. /edit
/// replaces the whole file with this body, so starting from raw is what keeps unmodeled keys
/// (extension metadata, future upstream fields) alive across our edits. A draft or raw-less group
/// has nothing to preserve and gets a from-scratch body.
pub fn buildEditPayload(a: Allocator, g: *const Group) Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    var root: std.json.Value = .{ .object = .empty };
    if (g.raw.len > 0) {
        if (std.json.parseFromSliceLeaky(std.json.Value, ar, g.raw, .{}) catch null) |parsed| {
            if (parsed == .object) root = parsed;
        }
    }
    const obj = &root.object;
    try obj.put(ar, "id", .{ .string = g.id });
    try obj.put(ar, "name", .{ .string = g.name });
    try obj.put(ar, "avatar_url", .{ .string = g.avatar_url });
    try obj.put(ar, "chat_id", .{ .string = g.chat_id });
    try obj.put(ar, "members", try stringArray(ar, g.members.items));
    try obj.put(ar, "disabled_members", try stringArray(ar, g.disabled.items));
    try obj.put(ar, "activation_strategy", .{ .integer = @intFromEnum(g.activation_strategy) });
    try obj.put(ar, "generation_mode", .{ .integer = @intFromEnum(g.generation_mode) });
    try obj.put(ar, "allow_self_responses", .{ .bool = g.allow_self_responses });
    try obj.put(ar, "fav", .{ .bool = g.fav });
    if (obj.get("chats") == null) {
        var chats = std.json.Array.init(ar);
        try chats.append(.{ .string = g.chat_id });
        try obj.put(ar, "chats", .{ .array = chats });
    }
    return std.json.Stringify.valueAlloc(a, root, .{}) catch return error.OutOfMemory;
}

fn stringArray(a: Allocator, items: []const []const u8) Allocator.Error!std.json.Value {
    var arr = std.json.Array.init(a);
    try arr.ensureTotalCapacityPrecise(items.len);
    for (items) |s| arr.appendAssumeCapacity(.{ .string = s });
    return .{ .array = arr };
}

// ---- the global instance + module accessors (mirrors character_store) -------------------------

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const page_gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;

pub var global: GroupStore = .{ .allocator = page_gpa };

pub fn slice() []const Group {
    return global.slice();
}

pub fn selected() ?Group {
    return global.selected();
}

pub fn selectedIndex() ?usize {
    return global.selected_index;
}

pub fn select(index: usize) void {
    global.select(index);
}

pub fn deselect() void {
    global.deselect();
}

pub fn byId(id: []const u8) ?*const Group {
    return global.byId(id);
}

// ---- the send-loop surface (frozen interface) -------------------------------------------------

/// Registered by the send/load side; the roster panel calls it when the user activates a group row
/// (open its chat). Null until registered: the panel then selects without opening.
pub var on_group_open: ?*const fn (index: usize) void = null;

/// The open group's id, the value the /group/* + append routes take as group_id / id. Null when no
/// group is selected or the selection is an unsaved draft: both mean the send loop is in solo mode.
pub fn activeGroupId() ?[]const u8 {
    const g = selected() orelse return null;
    return if (g.id.len > 0) g.id else null;
}

/// The open group's active chat file id (groupChats/<chat_id>.jsonl). Same solo-mode nulls as
/// activeGroupId.
pub fn activeChatId() ?[]const u8 {
    const g = selected() orelse return null;
    if (g.id.len == 0) return null;
    return if (g.chat_id.len > 0) g.chat_id else g.id;
}

pub fn isMuted(g: *const Group, member_avatar: []const u8) bool {
    return indexOfString(g.disabled.items, member_avatar) != null;
}

/// The members eligible for activation, in members order (the list-strategy order): members minus
/// muted. Caller owns the returned slice (free it); the strings are borrowed from the store and
/// live until the next roster reload or CRUD.
pub fn activationOrder(g: *const Group, a: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for (g.members.items) |m| {
        if (isMuted(g, m)) continue;
        try out.append(a, m);
    }
    return try out.toOwnedSlice(a);
}

/// Resolve a member avatar filename to its character_store index (the card the member's prompt is
/// built from). Null when the character is not loaded (deleted or renamed since the group was made).
pub fn memberCharacterIndex(member_avatar: []const u8) ?usize {
    return memberCharacterIndexIn(character_store.slice(), member_avatar);
}

pub fn memberCharacterIndexIn(chars: []const character_store.Character, member_avatar: []const u8) ?usize {
    for (chars, 0..) |c, i| {
        if (std.mem.eql(u8, c.avatar, member_avatar)) return i;
    }
    return null;
}

// ---- panel view state (list vs editor; pure so the transitions are testable) ------------------

/// Which group the panel's editor shows; null = the roster list. Distinct from selected_index (the
/// OPEN group, the send target): editing a group must not retarget the send loop.
pub var editing_index: ?usize = null;

pub fn openEditor(index: usize) void {
    editing_index = if (index < global.groups.items.len) index else null;
}

pub fn closeEditor() void {
    editing_index = null;
}

pub fn editingGroup() ?*const Group {
    const i = editing_index orelse return null;
    if (i >= global.groups.items.len) return null;
    return &global.groups.items[i];
}

/// Remove from the GLOBAL store, keeping editing_index (module view state) pinned the same way
/// removeAt pins selected_index. Callers on the global store use this, never global.removeAt raw.
pub fn removeGroupAt(index: usize) void {
    if (index >= global.groups.items.len) return;
    global.removeAt(index);
    if (editing_index) |e| {
        if (e == index) {
            editing_index = null;
        } else if (e > index) {
            editing_index = e - 1;
        }
    }
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

fn parseValue(a: Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, body, .{});
}

const all_fixture =
    \\[
    \\ {"id":"1700000000001","name":"Adventurers","members":["alice.png","bob.png"],
    \\  "avatar_url":"grp.png","allow_self_responses":false,"activation_strategy":1,
    \\  "generation_mode":0,"disabled_members":["bob.png"],"fav":true,"chat_id":"1700000000001",
    \\  "chats":["1700000000001"],"auto_mode_delay":5,"generation_mode_join_prefix":"",
    \\  "generation_mode_join_suffix":"","date_added":1700000000001.0,
    \\  "create_date":"2023-11-14T22:13:20.001Z","date_last_chat":1700000500000.5,"chat_size":123},
    \\ {"name":"no id, dropped"},
    \\ "not an object",
    \\ {"id":1700000000002,"members":["carol.png",42,""],"activation_strategy":99}
    \\]
;

test "replaceAll parses the roster, drops unusable entries, and tolerates odd shapes" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    const parsed = try parseValue(testing.allocator, all_fixture);
    defer parsed.deinit();
    try store.replaceAll(parsed.value);

    try testing.expectEqual(@as(usize, 2), store.slice().len);
    const g = store.slice()[0];
    try testing.expectEqualStrings("1700000000001", g.id);
    try testing.expectEqualStrings("Adventurers", g.name);
    try testing.expectEqualStrings("grp.png", g.avatar_url);
    try testing.expectEqualStrings("1700000000001", g.chat_id);
    try testing.expectEqual(@as(usize, 2), g.memberSlice().len);
    try testing.expectEqualStrings("alice.png", g.memberSlice()[0]);
    try testing.expectEqual(ActivationStrategy.list, g.activation_strategy);
    try testing.expectEqual(GenerationMode.swap, g.generation_mode);
    try testing.expect(g.fav);
    try testing.expect(!g.allow_self_responses);
    // The float mtimeMs truncates to whole ms.
    try testing.expectEqual(@as(u64, 1700000500000), g.date_last_chat);
    try testing.expect(isMuted(&store.groups.items[0], "bob.png"));
    try testing.expect(!isMuted(&store.groups.items[0], "alice.png"));

    // The numeric id renders to its decimal string; the non-string member is dropped, not fatal;
    // chat_id falls back to the id; the unknown strategy int is preserved, not corrupted to 0.
    const g2 = store.slice()[1];
    try testing.expectEqualStrings("1700000000002", g2.id);
    try testing.expectEqualStrings("1700000000002", g2.chat_id);
    try testing.expectEqual(@as(usize, 1), g2.memberSlice().len);
    try testing.expectEqualStrings("carol.png", g2.memberSlice()[0]);
    try testing.expectEqual(@as(u8, 99), @intFromEnum(g2.activation_strategy));
}

test "replaceAll swaps rather than appends and re-finds the selection by id" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    const parsed = try parseValue(testing.allocator, all_fixture);
    defer parsed.deinit();
    try store.replaceAll(parsed.value);
    store.select(1);

    // A reload that reorders the roster keeps the selection on the same group.
    const reordered =
        \\[{"id":"1700000000002","members":[]},
        \\ {"id":"1700000000001","name":"Adventurers","members":["alice.png"]}]
    ;
    const parsed2 = try parseValue(testing.allocator, reordered);
    defer parsed2.deinit();
    try store.replaceAll(parsed2.value);
    try testing.expectEqual(@as(usize, 2), store.slice().len);
    try testing.expectEqual(@as(?usize, 0), store.selected_index);
    try testing.expectEqualStrings("1700000000002", store.selected().?.id);

    // A reload that dropped the selected group clears the selection.
    const gone = "[{\"id\":\"1700000000001\",\"members\":[]}]";
    const parsed3 = try parseValue(testing.allocator, gone);
    defer parsed3.deinit();
    try store.replaceAll(parsed3.value);
    try testing.expectEqual(@as(?usize, null), store.selected_index);
}

test "a non-array body reads as an empty roster, never a crash" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    const parsed = try parseValue(testing.allocator, "{\"error\":\"nope\"}");
    defer parsed.deinit();
    try store.replaceAll(parsed.value);
    try testing.expectEqual(@as(usize, 0), store.slice().len);
}

test "membership mutations: add dedupes, remove unmutes, move reorders, mute round-trips" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    const parsed = try parseValue(testing.allocator, all_fixture);
    defer parsed.deinit();
    try store.replaceAll(parsed.value);

    try store.addMember(0, "carol.png");
    try store.addMember(0, "carol.png");
    try store.addMember(0, "");
    try testing.expectEqual(@as(usize, 3), store.slice()[0].memberSlice().len);
    try testing.expectEqualStrings("carol.png", store.slice()[0].memberSlice()[2]);

    store.moveMember(0, 2, 0);
    try testing.expectEqualStrings("carol.png", store.slice()[0].memberSlice()[0]);
    try testing.expectEqualStrings("alice.png", store.slice()[0].memberSlice()[1]);
    store.moveMember(0, 0, 9);
    try testing.expectEqualStrings("carol.png", store.slice()[0].memberSlice()[0]);

    // Muting a non-member is a no-op; unmute removes the entry; removing a member drops its mute.
    try store.setMuted(0, "nobody.png", true);
    try testing.expectEqual(@as(usize, 1), store.slice()[0].mutedSlice().len);
    try store.setMuted(0, "carol.png", true);
    try testing.expectEqual(@as(usize, 2), store.slice()[0].mutedSlice().len);
    try store.setMuted(0, "carol.png", false);
    try testing.expectEqual(@as(usize, 1), store.slice()[0].mutedSlice().len);
    store.removeMember(0, "bob.png");
    try testing.expectEqual(@as(usize, 2), store.slice()[0].memberSlice().len);
    try testing.expectEqual(@as(usize, 0), store.slice()[0].mutedSlice().len);
}

test "activationOrder is members minus muted, in members order" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    const parsed = try parseValue(testing.allocator, all_fixture);
    defer parsed.deinit();
    try store.replaceAll(parsed.value);
    try store.addMember(0, "carol.png");

    const order = try activationOrder(&store.groups.items[0], testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 2), order.len);
    try testing.expectEqualStrings("alice.png", order[0]);
    try testing.expectEqualStrings("carol.png", order[1]);
}

test "memberCharacterIndexIn resolves an avatar to its character row and misses cleanly" {
    const chars = [_]character_store.Character{
        .{ .name = "Alice", .avatar = "alice.png", .description = "", .personality = "", .first_mes = "", .scenario = "", .mes_example = "", .chat = "", .fav = false, .tags = &.{} },
        .{ .name = "Bob", .avatar = "bob.png", .description = "", .personality = "", .first_mes = "", .scenario = "", .mes_example = "", .chat = "", .fav = false, .tags = &.{} },
    };
    try testing.expectEqual(@as(?usize, 1), memberCharacterIndexIn(&chars, "bob.png"));
    try testing.expectEqual(@as(?usize, null), memberCharacterIndexIn(&chars, "gone.png"));
    try testing.expectEqual(@as(?usize, null), memberCharacterIndexIn(&chars, ""));
}

test "draft: appendDraft is local-only, activeGroupId stays solo, promoteDraft adopts the response" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    const di = try store.appendDraft("New Group");
    try testing.expectEqual(@as(usize, 0), di);
    try testing.expect(store.slice()[0].isDraft());
    try store.addMember(di, "alice.png");

    // A selected draft must read as solo mode to the send loop (module-level check via a scoped
    // global swap: the module accessors read `global`).
    const saved = global;
    global = store;
    defer {
        store = global;
        global = saved;
    }
    global.select(di);
    try testing.expectEqual(@as(?[]const u8, null), activeGroupId());
    try testing.expectEqual(@as(?[]const u8, null), activeChatId());

    const created =
        \\{"id":"42","name":"New Group","members":["alice.png"],"chat_id":"42","chats":["42"],
        \\ "activation_strategy":0,"generation_mode":0,"disabled_members":[]}
    ;
    try testing.expect(try global.promoteDraft(di, created));
    try testing.expect(!global.slice()[0].isDraft());
    try testing.expectEqualStrings("42", activeGroupId().?);
    try testing.expectEqualStrings("42", activeChatId().?);

    // A garbage response keeps the draft (the picked roster survives).
    const di2 = try global.appendDraft("Other");
    try testing.expect(!try global.promoteDraft(di2, "not json"));
    try testing.expect(global.slice()[di2].isDraft());
}

test "removeAt keeps the selection pinned to the group it pointed at" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    _ = try store.appendDraft("a");
    _ = try store.appendDraft("b");
    _ = try store.appendDraft("c");
    store.select(2);
    store.removeAt(0);
    try testing.expectEqual(@as(?usize, 1), store.selected_index);
    try testing.expectEqualStrings("c", store.selected().?.name);
    store.removeAt(1);
    try testing.expectEqual(@as(?usize, null), store.selected_index);
}

test "buildCreatePayload carries the drafted roster and knobs" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    const di = try store.appendDraft("My Group");
    try store.addMember(di, "alice.png");
    try store.addMember(di, "bob.png");
    try store.setMuted(di, "bob.png", true);
    store.setStrategy(di, .list);
    store.setAllowSelf(di, true);

    const body = try buildCreatePayload(testing.allocator, &store.groups.items[di]);
    defer testing.allocator.free(body);
    const parsed = try parseValue(testing.allocator, body);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("My Group", obj.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), obj.get("members").?.array.items.len);
    try testing.expectEqualStrings("bob.png", obj.get("disabled_members").?.array.items[0].string);
    try testing.expectEqual(@as(i64, 1), obj.get("activation_strategy").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("generation_mode").?.integer);
    try testing.expect(obj.get("allow_self_responses").?.bool);
}

test "buildEditPayload patches modeled fields and keeps unmodeled keys alive" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    const entry =
        \\[{"id":"7","name":"Old","members":["alice.png"],"chat_id":"7","chats":["7","8"],
        \\  "auto_mode_delay":9,"generation_mode_join_prefix":"<p>","custom_ext":{"keep":"me"},
        \\  "activation_strategy":0}]
    ;
    const parsed = try parseValue(testing.allocator, entry);
    defer parsed.deinit();
    try store.replaceAll(parsed.value);
    try store.rename(0, "New Name");
    try store.addMember(0, "bob.png");
    store.setStrategy(0, .pooled);

    const body = try buildEditPayload(testing.allocator, &store.groups.items[0]);
    defer testing.allocator.free(body);
    const out = try parseValue(testing.allocator, body);
    defer out.deinit();
    const obj = out.value.object;
    // Patched.
    try testing.expectEqualStrings("New Name", obj.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), obj.get("members").?.array.items.len);
    try testing.expectEqual(@as(i64, 3), obj.get("activation_strategy").?.integer);
    // Preserved: the keys this client does not model survive the round-trip (the /edit route
    // replaces the whole file, so dropping them here would be silent data loss).
    try testing.expectEqualStrings("me", obj.get("custom_ext").?.object.get("keep").?.string);
    try testing.expectEqual(@as(i64, 9), obj.get("auto_mode_delay").?.integer);
    try testing.expectEqualStrings("<p>", obj.get("generation_mode_join_prefix").?.string);
    try testing.expectEqual(@as(usize, 2), obj.get("chats").?.array.items.len);
    try testing.expectEqualStrings("7", obj.get("id").?.string);
}

test "buildEditPayload for a raw-less group still yields a complete file body" {
    var store = GroupStore.init(testing.allocator);
    defer store.deinit();
    const di = try store.appendDraft("Fresh");
    try store.addMember(di, "alice.png");
    const g = &store.groups.items[di];

    const body = try buildEditPayload(testing.allocator, g);
    defer testing.allocator.free(body);
    const out = try parseValue(testing.allocator, body);
    defer out.deinit();
    const obj = out.value.object;
    try testing.expectEqualStrings("Fresh", obj.get("name").?.string);
    try testing.expectEqual(@as(usize, 1), obj.get("members").?.array.items.len);
    try testing.expect(obj.get("chats") != null);
}

test "removeGroupAt pins the editor to the group it was editing" {
    const saved = global;
    global = GroupStore.init(testing.allocator);
    defer {
        global.deinit();
        global = saved;
        editing_index = null;
    }
    _ = try global.appendDraft("a");
    _ = try global.appendDraft("b");
    _ = try global.appendDraft("c");
    openEditor(2);
    removeGroupAt(0);
    try testing.expectEqual(@as(?usize, 1), editing_index);
    try testing.expectEqualStrings("c", editingGroup().?.name);
    removeGroupAt(1);
    try testing.expectEqual(@as(?usize, null), editing_index);
}

test "editor view state opens in range, rejects out of range, and closes" {
    const saved = global;
    global = GroupStore.init(testing.allocator);
    defer {
        global.deinit();
        global = saved;
        editing_index = null;
    }
    _ = try global.appendDraft("a");
    openEditor(0);
    try testing.expectEqual(@as(?usize, 0), editing_index);
    try testing.expectEqualStrings("a", editingGroup().?.name);
    openEditor(5);
    try testing.expectEqual(@as(?usize, null), editing_index);
    openEditor(0);
    closeEditor();
    try testing.expect(editingGroup() == null);
}

fn rosterLifecycle(alloc: Allocator) !void {
    var store = GroupStore.init(alloc);
    defer store.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, all_fixture, .{});
    defer parsed.deinit();
    try store.replaceAll(parsed.value);
    try store.addMember(0, "carol.png");
    try store.setMuted(0, "carol.png", true);
    try store.rename(0, "Renamed");
    const body = try buildEditPayload(alloc, &store.groups.items[0]);
    alloc.free(body);
    const create = try buildCreatePayload(alloc, &store.groups.items[0]);
    alloc.free(create);
    const order = try activationOrder(&store.groups.items[0], alloc);
    alloc.free(order);
    store.removeMember(0, "alice.png");
    store.removeAt(0);
}

test "the roster lifecycle cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, rosterLifecycle, .{});
}
