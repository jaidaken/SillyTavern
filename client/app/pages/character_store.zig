const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.chars);

pub const Character = struct {
    name: []const u8,
    avatar: []const u8,
    description: []const u8,
    personality: []const u8,
    first_mes: []const u8,
    scenario: []const u8,
    mes_example: []const u8,
    chat: []const u8,
    fav: bool,
    tags: []const []const u8,

    /// Metadata used by the list view (sort/search). Derived from /api/characters/all (toShallow).
    create_date: []const u8 = "",
    date_last_chat: u64 = 0,
    chat_size: u64 = 0,
    data_size: u64 = 0,

    name_owned: ?[]const u8 = null,
    avatar_owned: ?[]const u8 = null,
    description_owned: ?[]const u8 = null,
    personality_owned: ?[]const u8 = null,
    first_mes_owned: ?[]const u8 = null,
    scenario_owned: ?[]const u8 = null,
    mes_example_owned: ?[]const u8 = null,
    chat_owned: ?[]const u8 = null,
    tags_owned: ?[]const []const u8 = null,
    create_date_owned: ?[]const u8 = null,
};

pub const CharacterStore = struct {
    allocator: Allocator,
    characters: std.ArrayList(Character) = .empty,
    selected_index: ?usize = null,

    pub fn init(allocator: Allocator) CharacterStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CharacterStore) void {
        for (self.characters.items) |c| self.freeCharacter(c);
        self.characters.deinit(self.allocator);
        self.* = undefined;
    }

    fn freeCharacter(self: *CharacterStore, c: Character) void {
        if (c.name_owned) |b| self.allocator.free(b);
        if (c.avatar_owned) |b| self.allocator.free(b);
        if (c.description_owned) |b| self.allocator.free(b);
        if (c.personality_owned) |b| self.allocator.free(b);
        if (c.first_mes_owned) |b| self.allocator.free(b);
        if (c.scenario_owned) |b| self.allocator.free(b);
        if (c.mes_example_owned) |b| self.allocator.free(b);
        if (c.chat_owned) |b| self.allocator.free(b);
        if (c.tags_owned) |b| {
            for (b) |t| self.allocator.free(t);
            self.allocator.free(b);
        }
        if (c.create_date_owned) |b| self.allocator.free(b);
    }

    pub fn slice(self: *const CharacterStore) []const Character {
        return self.characters.items;
    }

    pub fn selected(self: *const CharacterStore) ?Character {
        const i = self.selected_index orelse return null;
        if (i >= self.characters.items.len) return null;
        return self.characters.items[i];
    }

    pub fn select(self: *CharacterStore, index: usize) void {
        self.selected_index = if (index < self.characters.items.len) index else null;
        log.debug("store select: {d} -> {?d}", .{ index, self.selected_index });
    }

    pub fn clear(self: *CharacterStore) void {
        log.debug("store clear: {d} characters", .{self.characters.items.len});
        for (self.characters.items) |c| self.freeCharacter(c);
        self.characters.clearRetainingCapacity();
        self.selected_index = null;
    }

    pub fn append(self: *CharacterStore, c: Character) Allocator.Error!void {
        try self.characters.append(self.allocator, c);
        log.debug("store append: {s} ({d} total)", .{ c.name, self.characters.items.len });
    }

    /// Attach list-view metadata (sort/search) to the character at `index`, taking ownership of
    /// `create_date`. No-op if the index is out of range. Used by the door after the host loads a
    /// character from /api/characters/all.
    pub fn setMeta(self: *CharacterStore, index: usize, create_date: []const u8, date_last_chat: u64, chat_size: u64, data_size: u64) void {
        if (index >= self.characters.items.len) return;
        const c = &self.characters.items[index];
        if (c.create_date_owned) |b| self.allocator.free(b);
        c.create_date = "";
        c.create_date_owned = null;
        if (create_date.len > 0) {
            c.create_date = self.allocator.dupe(u8, create_date) catch "";
            if (c.create_date.len > 0) c.create_date_owned = c.create_date;
        }
        c.date_last_chat = date_last_chat;
        c.chat_size = chat_size;
        c.data_size = data_size;
        log.debug("store setMeta: {d} last_chat={d} chat_size={d} data_size={d}", .{ index, date_last_chat, chat_size, data_size });
    }
};

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const page_gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;

pub var global: CharacterStore = .{ .allocator = page_gpa };

pub fn slice() []const Character {
    return global.slice();
}

pub fn selected() ?Character {
    return global.selected();
}

pub fn selectedIndex() ?usize {
    return global.selected_index;
}

pub fn select(index: usize) void {
    global.select(index);
}
