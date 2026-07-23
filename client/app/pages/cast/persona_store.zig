const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const Persona = struct {
    name: []const u8,
    avatar: []const u8,
    description: []const u8,

    name_owned: ?[]u8 = null,
    avatar_owned: ?[]u8 = null,
    description_owned: ?[]u8 = null,
};

pub const PersonaStore = struct {
    allocator: Allocator,
    personas: std.ArrayList(Persona) = .empty,
    selected_index: ?usize = null,

    pub fn init(allocator: Allocator) PersonaStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PersonaStore) void {
        for (self.personas.items) |p| self.freePersona(p);
        self.personas.deinit(self.allocator);
        self.* = undefined;
    }

    fn freePersona(self: *PersonaStore, p: Persona) void {
        if (p.name_owned) |b| self.allocator.free(b);
        if (p.avatar_owned) |b| self.allocator.free(b);
        if (p.description_owned) |b| self.allocator.free(b);
    }

    pub fn slice(self: *const PersonaStore) []const Persona {
        return self.personas.items;
    }

    pub fn selected(self: *const PersonaStore) ?Persona {
        const i = self.selected_index orelse return null;
        if (i >= self.personas.items.len) return null;
        return self.personas.items[i];
    }

    pub fn select(self: *PersonaStore, index: usize) void {
        self.selected_index = if (index < self.personas.items.len) index else null;
    }

    pub fn clear(self: *PersonaStore) void {
        for (self.personas.items) |p| self.freePersona(p);
        self.personas.clearRetainingCapacity();
        self.selected_index = null;
    }

    pub fn append(self: *PersonaStore, p: Persona) Allocator.Error!void {
        try self.personas.append(self.allocator, p);
    }
};

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const page_gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;

pub var global: PersonaStore = .{ .allocator = page_gpa };

pub fn slice() []const Persona {
    return global.slice();
}

pub fn selected() ?Persona {
    return global.selected();
}

pub fn selectedIndex() ?usize {
    return global.selected_index;
}

pub fn select(index: usize) void {
    global.select(index);
}
