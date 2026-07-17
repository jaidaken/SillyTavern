//! Account-level tags (3d): the `tags` array and the `tag_map` avatar index of the settings blob,
//! the same keys the classic client's tags.js reads and writes.
//!
//! Pure Zig so the model unit-tests natively (ZX5): mining takes the raw settings string, mutation
//! is plain state, and persistence rides reading_prefs' ONE debounced saver via `mergeTags` (a
//! second read-modify-write saver would clobber the blob). The panel's zx side owns the DOM and the
//! `scheduleSave` calls.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Tag = struct {
    id: []u8,
    name: []u8,
    color: []u8,
    color2: []u8,
    folder_type: []u8,
    sort_order: i64,
    /// The tag's ORIGINAL blob object, verbatim. The saver patches only the modeled keys into it,
    /// so fields this client does not model (create_date, future upstream keys) survive a rewrite
    /// instead of being clobbered. Empty for a tag created here.
    raw: []u8 = &.{},
};

const MapEntry = struct {
    avatar: []u8,
    ids: std.ArrayList([]u8) = .empty,
};

pub const TagStore = struct {
    allocator: Allocator,
    tags: std.ArrayList(Tag) = .empty,
    map: std.ArrayList(MapEntry) = .empty,

    pub fn init(allocator: Allocator) TagStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TagStore) void {
        self.clear();
        self.tags.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *TagStore) void {
        for (self.tags.items) |t| self.freeTag(t);
        self.tags.clearRetainingCapacity();
        for (self.map.items) |*e| self.freeEntry(e);
        self.map.clearRetainingCapacity();
    }

    fn freeTag(self: *TagStore, t: Tag) void {
        self.allocator.free(t.id);
        self.allocator.free(t.name);
        self.allocator.free(t.color);
        self.allocator.free(t.color2);
        self.allocator.free(t.folder_type);
        if (t.raw.len > 0) self.allocator.free(t.raw);
    }

    fn freeEntry(self: *TagStore, e: *MapEntry) void {
        self.allocator.free(e.avatar);
        for (e.ids.items) |id| self.allocator.free(id);
        e.ids.deinit(self.allocator);
    }

    /// Replace the store with the `tags` + `tag_map` keys of a raw settings string. Tolerant like
    /// every other blob miner: a missing key, wrong type, or malformed row degrades to absent
    /// rather than erroring, so one hostile field never empties the whole account.
    pub fn mine(self: *TagStore, settings_str: []const u8) Allocator.Error!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), settings_str, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        if (parsed != .object) return;
        self.clear();

        if (parsed.object.get("tags")) |v| if (v == .array) {
            for (v.array.items) |item| {
                if (item != .object) continue;
                const o = item.object;
                const id = strField(o, "id") orelse continue;
                if (id.len == 0) continue;
                const raw = try std.json.Stringify.valueAlloc(arena.allocator(), item, .{});
                try self.putTag(.{
                    .id = id,
                    .name = strField(o, "name") orelse "",
                    .color = strField(o, "color") orelse "",
                    .color2 = strField(o, "color2") orelse "",
                    .folder_type = strField(o, "folder_type") orelse "NONE",
                    .sort_order = intField(o, "sort_order") orelse @intCast(self.tags.items.len),
                    .raw = raw,
                });
            }
        };

        if (parsed.object.get("tag_map")) |v| if (v == .object) {
            var it = v.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* != .array) continue;
                for (kv.value_ptr.array.items) |idv| {
                    if (idv != .string) continue;
                    if (self.byId(idv.string) == null) continue;
                    try self.assign(kv.key_ptr.*, idv.string);
                }
            }
        };
    }

    fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const v = o.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    fn intField(o: std.json.ObjectMap, key: []const u8) ?i64 {
        const v = o.get(key) orelse return null;
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }

    fn putTag(self: *TagStore, borrowed: struct { id: []const u8, name: []const u8, color: []const u8, color2: []const u8, folder_type: []const u8, sort_order: i64, raw: []const u8 = &.{} }) Allocator.Error!void {
        const id = try self.allocator.dupe(u8, borrowed.id);
        errdefer self.allocator.free(id);
        const name = try self.allocator.dupe(u8, borrowed.name);
        errdefer self.allocator.free(name);
        const color = try self.allocator.dupe(u8, borrowed.color);
        errdefer self.allocator.free(color);
        const color2 = try self.allocator.dupe(u8, borrowed.color2);
        errdefer self.allocator.free(color2);
        const folder = try self.allocator.dupe(u8, borrowed.folder_type);
        errdefer self.allocator.free(folder);
        const raw: []u8 = if (borrowed.raw.len > 0) try self.allocator.dupe(u8, borrowed.raw) else &.{};
        errdefer if (raw.len > 0) self.allocator.free(raw);
        try self.tags.append(self.allocator, .{ .id = id, .name = name, .color = color, .color2 = color2, .folder_type = folder, .sort_order = borrowed.sort_order, .raw = raw });
    }

    pub fn byId(self: *const TagStore, id: []const u8) ?*const Tag {
        for (self.tags.items) |*t| {
            if (std.mem.eql(u8, t.id, id)) return t;
        }
        return null;
    }

    pub fn byName(self: *const TagStore, name: []const u8) ?*const Tag {
        for (self.tags.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    /// Create a tag with a caller-supplied id (the zx side derives it from the clock; pure code
    /// takes no entropy). A duplicate name or id is a no-op returning the existing tag's id slice.
    pub fn create(self: *TagStore, id: []const u8, name: []const u8) Allocator.Error![]const u8 {
        if (name.len == 0 or id.len == 0) return "";
        if (self.byName(name)) |t| return t.id;
        if (self.byId(id)) |t| return t.id;
        try self.putTag(.{ .id = id, .name = name, .color = "", .color2 = "", .folder_type = "NONE", .sort_order = @intCast(self.tags.items.len) });
        return self.tags.items[self.tags.items.len - 1].id;
    }

    pub fn setColor(self: *TagStore, id: []const u8, color: []const u8, color2: []const u8) Allocator.Error!void {
        for (self.tags.items) |*t| {
            if (!std.mem.eql(u8, t.id, id)) continue;
            const c = try self.allocator.dupe(u8, color);
            const c2 = self.allocator.dupe(u8, color2) catch |err| {
                self.allocator.free(c);
                return err;
            };
            self.allocator.free(t.color);
            self.allocator.free(t.color2);
            t.color = c;
            t.color2 = c2;
            return;
        }
    }

    fn entryFor(self: *TagStore, avatar: []const u8) ?*MapEntry {
        for (self.map.items) |*e| {
            if (std.mem.eql(u8, e.avatar, avatar)) return e;
        }
        return null;
    }

    pub fn isAssigned(self: *const TagStore, avatar: []const u8, id: []const u8) bool {
        for (self.map.items) |e| {
            if (!std.mem.eql(u8, e.avatar, avatar)) continue;
            for (e.ids.items) |have| {
                if (std.mem.eql(u8, have, id)) return true;
            }
        }
        return false;
    }

    pub fn assign(self: *TagStore, avatar: []const u8, id: []const u8) Allocator.Error!void {
        if (avatar.len == 0 or id.len == 0) return;
        if (self.isAssigned(avatar, id)) return;
        if (self.entryFor(avatar)) |e| {
            const owned = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(owned);
            try e.ids.append(self.allocator, owned);
            return;
        }
        const av = try self.allocator.dupe(u8, avatar);
        errdefer self.allocator.free(av);
        var entry: MapEntry = .{ .avatar = av };
        errdefer entry.ids.deinit(self.allocator);
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try entry.ids.append(self.allocator, owned);
        try self.map.append(self.allocator, entry);
    }

    pub fn unassign(self: *TagStore, avatar: []const u8, id: []const u8) void {
        const e = self.entryFor(avatar) orelse return;
        for (e.ids.items, 0..) |have, i| {
            if (!std.mem.eql(u8, have, id)) continue;
            self.allocator.free(have);
            _ = e.ids.orderedRemove(i);
            return;
        }
    }

    /// Write `tags` + `tag_map` into the settings object the one saver is about to persist.
    /// `a` is the saver's arena, matching every other mergeX (reading_prefs.zig:287-290). The
    /// modeled keys are PATCHED into each tag's original object, so fields this client does not
    /// model survive the rewrite (a modeled-fields-only rewrite would clobber the classic
    /// frontend's create_date and any future upstream key).
    pub fn mergeTags(self: *const TagStore, a: Allocator, root_obj: *std.json.ObjectMap) !void {
        var tags_arr: std.json.Array = .init(a);
        for (self.tags.items) |t| {
            var o: std.json.ObjectMap = base: {
                if (t.raw.len > 0) {
                    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, t.raw, .{}) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => break :base .empty,
                    };
                    if (parsed == .object) break :base parsed.object;
                }
                break :base .empty;
            };
            try o.put(a, "id", .{ .string = try a.dupe(u8, t.id) });
            try o.put(a, "name", .{ .string = try a.dupe(u8, t.name) });
            try o.put(a, "color", .{ .string = try a.dupe(u8, t.color) });
            try o.put(a, "color2", .{ .string = try a.dupe(u8, t.color2) });
            try o.put(a, "folder_type", .{ .string = try a.dupe(u8, t.folder_type) });
            try o.put(a, "sort_order", .{ .integer = t.sort_order });
            try tags_arr.append(.{ .object = o });
        }
        try root_obj.put(a, "tags", .{ .array = tags_arr });

        var map_obj: std.json.ObjectMap = .empty;
        for (self.map.items) |e| {
            var ids: std.json.Array = .init(a);
            for (e.ids.items) |id| try ids.append(.{ .string = try a.dupe(u8, id) });
            try map_obj.put(a, try a.dupe(u8, e.avatar), .{ .array = ids });
        }
        try root_obj.put(a, "tag_map", .{ .object = map_obj });
    }
};

/// The one store the page uses; wasm allocator on the client, page allocator natively.
pub var global: TagStore = .{ .allocator = @import("./store.zig").page_gpa };

const testing = std.testing;

test "mine lifts tags and tag_map and degrades hostile rows to absent" {
    var s = TagStore.init(testing.allocator);
    defer s.deinit();
    try s.mine(
        \\{"tags":[{"id":"t1","name":"harbor","color":"#123","color2":"","folder_type":"NONE","sort_order":1},
        \\         {"id":"","name":"no id"}, {"name":"still no id"}, 7, {"id":"t2","name":"night"}],
        \\ "tag_map":{"char41.png":["t1","missing","t2"],"bad.png":"not-an-array","other.png":["t2",5]}}
    );
    try testing.expectEqual(@as(usize, 2), s.tags.items.len);
    try testing.expectEqualStrings("harbor", s.byId("t1").?.name);
    try testing.expectEqualStrings("#123", s.byId("t1").?.color);
    try testing.expect(s.isAssigned("char41.png", "t1"));
    try testing.expect(s.isAssigned("char41.png", "t2"));
    try testing.expect(!s.isAssigned("char41.png", "missing"));
    try testing.expect(s.isAssigned("other.png", "t2"));
    try testing.expect(!s.isAssigned("bad.png", "t2"));
}

test "mine tolerates a malformed or non-object settings string" {
    var s = TagStore.init(testing.allocator);
    defer s.deinit();
    _ = try s.create("t1", "kept until a real mine replaces it");
    try s.mine("{nope");
    try testing.expectEqual(@as(usize, 1), s.tags.items.len);
    try s.mine("42");
    try testing.expectEqual(@as(usize, 1), s.tags.items.len);
    try s.mine("{}");
    try testing.expectEqual(@as(usize, 0), s.tags.items.len);
}

test "create assign color unassign round-trips through merge and a fresh mine" {
    var s = TagStore.init(testing.allocator);
    defer s.deinit();
    const id = try s.create("tag-100", "harbor");
    try testing.expectEqualStrings("tag-100", id);
    // Duplicate name returns the existing id instead of forking the tag.
    try testing.expectEqualStrings("tag-100", try s.create("tag-200", "harbor"));
    try s.setColor("tag-100", "#a05a2c", "#fff8ef");
    try s.assign("char41.png", "tag-100");
    _ = try s.create("tag-300", "night");
    try s.assign("char41.png", "tag-300");
    s.unassign("char41.png", "tag-300");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: std.json.ObjectMap = .empty;
    try s.mergeTags(a, &root);
    const blob = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});

    var fresh = TagStore.init(testing.allocator);
    defer fresh.deinit();
    try fresh.mine(blob);
    try testing.expectEqual(@as(usize, 2), fresh.tags.items.len);
    try testing.expectEqualStrings("#a05a2c", fresh.byName("harbor").?.color);
    try testing.expect(fresh.isAssigned("char41.png", "tag-100"));
    try testing.expect(!fresh.isAssigned("char41.png", "tag-300"));
}

test "unmodeled tag fields survive a client color edit through the rewrite" {
    var s = TagStore.init(testing.allocator);
    defer s.deinit();
    // A stock-shaped tag the classic frontend wrote: create_date + a field no client models yet.
    try s.mine(
        \\{"tags":[{"id":"t1","name":"harbor","color":"#000000","color2":"","folder_type":"NONE","sort_order":3,
        \\          "create_date":"2025-01-02T03:04:05.000Z","unknown_future_field":{"deep":[1,2]}}],
        \\ "tag_map":{}}
    );
    try s.setColor("t1", "#a05a2c", "#fff8ef");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root: std.json.ObjectMap = .empty;
    try s.mergeTags(a, &root);
    const blob = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});

    const reread = try std.json.parseFromSliceLeaky(std.json.Value, a, blob, .{});
    const tag = reread.object.get("tags").?.array.items[0].object;
    // The edit landed...
    try testing.expectEqualStrings("#a05a2c", tag.get("color").?.string);
    try testing.expectEqualStrings("#fff8ef", tag.get("color2").?.string);
    // ...and every field the client does not model came through untouched.
    try testing.expectEqualStrings("2025-01-02T03:04:05.000Z", tag.get("create_date").?.string);
    try testing.expectEqual(@as(i64, 2), tag.get("unknown_future_field").?.object.get("deep").?.array.items[1].integer);
    try testing.expectEqual(@as(i64, 3), tag.get("sort_order").?.integer);
}

fn tagScenario(gpa: Allocator) !void {
    var s = TagStore.init(gpa);
    defer s.deinit();
    try s.mine(
        \\{"tags":[{"id":"t1","name":"harbor"}],"tag_map":{"a.png":["t1"]}}
    );
    _ = try s.create("t2", "night");
    try s.setColor("t2", "#123456", "#654321");
    try s.assign("a.png", "t2");
    try s.assign("b.png", "t2");
    s.unassign("a.png", "t1");
    try testing.expect(s.isAssigned("a.png", "t2"));
    try testing.expect(!s.isAssigned("a.png", "t1"));
}

test "tag store releases everything on any allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, tagScenario, .{});
}
