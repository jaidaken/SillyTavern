//! The variable macros: `{{getvar}}` / `{{setvar}}` / `{{addvar}}` / `{{incvar}}` / `{{decvar}}` and
//! their `globalvar` twins (public/scripts/variables.js:239 getVariableMacros).
//!
//! Two stores, and which one a macro touches is the only difference between the pairs: chat variables
//! live in the chat file's own metadata and belong to that conversation, globals live in the settings
//! blob and outlive it. Both are string maps; the numeric behaviour is a reading of the string, never a
//! second type, which is what lets a value survive a round trip through the store unchanged.
//!
//! Pure and zx-free so it joins the native `zig build test` aggregator.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One named store. Owns every key and value it holds, so a caller can hand it borrowed text.
pub const Store = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Set by any write. The host persists a store only when this is true, so a build that reads
    /// variables without setting one never rewrites a chat file or a settings blob.
    dirty: bool = false,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        self.map.deinit(alloc);
    }

    pub fn getRaw(self: *const Store, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    /// Stores `value` under `name`, replacing what was there. Both are copied.
    pub fn set(self: *Store, alloc: Allocator, name: []const u8, value: []const u8) Allocator.Error!void {
        const copy = try alloc.dupe(u8, value);
        errdefer alloc.free(copy);
        const found = try self.map.getOrPut(alloc, name);
        if (found.found_existing) {
            alloc.free(found.value_ptr.*);
        } else {
            found.key_ptr.* = alloc.dupe(u8, name) catch |e| {
                _ = self.map.remove(name);
                return e;
            };
        }
        found.value_ptr.* = copy;
        self.dirty = true;
    }
};

/// The pair a substitution pass reads and writes. Null stores leave the macros unresolved, which is
/// what a pass with no chat behind it wants: an untouched `{{getvar::x}}` beats an invented "".
pub const Stores = struct {
    chat: ?*Store = null,
    global: ?*Store = null,
};

/// Whether the whole string reads as a JavaScript number, the test `getLocalVariable` applies before
/// deciding to return a number instead of the stored text. Deliberately narrower than `Number()`: hex
/// and `Infinity` stay text here, which loses nothing (they render as themselves) and keeps the reading
/// of a stored value from depending on a parser's exotic corners.
fn numericValue(text: []const u8) ?f64 {
    if (text.len == 0) return null;
    var i: usize = 0;
    if (text[0] == '+' or text[0] == '-') i = 1;
    var digits: usize = 0;
    var dots: usize = 0;
    var exps: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '0'...'9' => digits += 1,
            '.' => {
                if (dots > 0 or exps > 0) return null;
                dots += 1;
            },
            'e', 'E' => {
                if (exps > 0 or digits == 0) return null;
                exps += 1;
                if (i + 1 < text.len and (text[i + 1] == '+' or text[i + 1] == '-')) i += 1;
                if (i + 1 >= text.len) return null;
            },
            else => return null,
        }
    }
    if (digits == 0) return null;
    return std.fmt.parseFloat(f64, text) catch null;
}

/// A number as JavaScript would print it: no trailing `.0` on a whole value.
fn renderNumber(alloc: Allocator, value: f64) Allocator.Error![]u8 {
    if (@floor(value) == value and @abs(value) < 1e21) {
        return std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(value))});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{value});
}

/// What `{{getvar}}` renders: the stored text, or its numeric reading when the whole string is one.
/// An unset name is the empty string, as stock's `?? ''` gives.
fn readValue(alloc: Allocator, store: *const Store, name: []const u8) Allocator.Error![]u8 {
    const raw = store.getRaw(name) orelse return alloc.dupe(u8, "");
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return alloc.dupe(u8, raw);
    if (numericValue(raw)) |n| return renderNumber(alloc, n);
    return alloc.dupe(u8, raw);
}

/// `addvar`, and the increment/decrement built on it. A value that reads as a number adds; anything
/// else concatenates, which is stock's fallback and the reason a counter and a log line can share one
/// macro. A stored JSON array appends instead, so `{{addvar::seen::owl}}` grows a list.
/// Returns the new value, which is what `{{incvar}}` and `{{decvar}}` render.
fn addValue(alloc: Allocator, store: *Store, name: []const u8, addend: []const u8) Allocator.Error![]u8 {
    const current = try readValue(alloc, store, name);
    defer alloc.free(current);

    if (try appendedArray(alloc, current, addend)) |json| {
        errdefer alloc.free(json);
        try store.set(alloc, name, json);
        return json;
    }

    const addend_num = numericValue(addend);
    const current_num = if (current.len == 0) @as(?f64, 0) else numericValue(current);
    if (addend_num == null or current_num == null) {
        const joined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ current, addend });
        errdefer alloc.free(joined);
        try store.set(alloc, name, joined);
        return joined;
    }
    const sum = try renderNumber(alloc, current_num.? + addend_num.?);
    errdefer alloc.free(sum);
    try store.set(alloc, name, sum);
    return sum;
}

/// `current` with `addend` pushed, when `current` is a JSON array; null otherwise. Owned.
fn appendedArray(alloc: Allocator, current: []const u8, addend: []const u8) Allocator.Error!?[]u8 {
    if (std.mem.trim(u8, current, " \t\r\n").len == 0 or current[0] != '[') return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, current, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    var items: std.ArrayList(std.json.Value) = .empty;
    defer items.deinit(alloc);
    try items.appendSlice(alloc, parsed.value.array.items);
    try items.append(alloc, .{ .string = addend });
    return try std.json.Stringify.valueAlloc(alloc, items.items, .{});
}

/// The `::`-separated body of a variable macro: the name, and whatever follows the second `::`.
const Parts = struct { name: []const u8, value: []const u8, has_value: bool };

fn split(body: []const u8) Parts {
    if (std.mem.indexOf(u8, body, "::")) |cut| {
        return .{ .name = std.mem.trim(u8, body[0..cut], " \t"), .value = body[cut + 2 ..], .has_value = true };
    }
    return .{ .name = std.mem.trim(u8, body, " \t"), .value = "", .has_value = false };
}

/// Resolves one variable macro. `inner` is the trimmed body between the braces. Returns null when it
/// names no variable macro, or when the store it needs is absent, so the caller keeps the literal.
pub fn resolve(alloc: Allocator, inner: []const u8, stores: Stores) Allocator.Error!?[]u8 {
    const table = .{
        .{ "getvar::", false, @as(u8, 'g') },
        .{ "setvar::", false, @as(u8, 's') },
        .{ "addvar::", false, @as(u8, 'a') },
        .{ "incvar::", false, @as(u8, 'i') },
        .{ "decvar::", false, @as(u8, 'd') },
        .{ "getglobalvar::", true, @as(u8, 'g') },
        .{ "setglobalvar::", true, @as(u8, 's') },
        .{ "addglobalvar::", true, @as(u8, 'a') },
        .{ "incglobalvar::", true, @as(u8, 'i') },
        .{ "decglobalvar::", true, @as(u8, 'd') },
    };
    inline for (table) |row| {
        if (std.mem.startsWith(u8, inner, row[0])) {
            const store = (if (row[1]) stores.global else stores.chat) orelse return null;
            return try apply(alloc, store, row[2], inner[row[0].len..]);
        }
    }
    return null;
}

fn apply(alloc: Allocator, store: *Store, op: u8, body: []const u8) Allocator.Error!?[]u8 {
    const parts = split(body);
    if (parts.name.len == 0) return null;
    switch (op) {
        'g' => return try readValue(alloc, store, parts.name),
        's' => {
            // A set with no value at all is not a set: stock's regex needs the second `::`.
            if (!parts.has_value) return null;
            try store.set(alloc, parts.name, parts.value);
            return try alloc.dupe(u8, "");
        },
        'a' => {
            if (!parts.has_value or parts.value.len == 0) return null;
            const out = try addValue(alloc, store, parts.name, parts.value);
            alloc.free(out);
            return try alloc.dupe(u8, "");
        },
        'i' => return try addValue(alloc, store, parts.name, "1"),
        'd' => return try addValue(alloc, store, parts.name, "-1"),
        else => return null,
    }
}

const testing = std.testing;

test "getvar_renders_a_stored_value_and_an_unset_name_is_empty" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);
    try chat.set(testing.allocator, "mood", "wary");

    const hit = (try resolve(testing.allocator, "getvar::mood", .{ .chat = &chat })).?;
    defer testing.allocator.free(hit);
    const miss = (try resolve(testing.allocator, "getvar::absent", .{ .chat = &chat })).?;
    defer testing.allocator.free(miss);

    try testing.expectEqualStrings("wary", hit);
    try testing.expectEqualStrings("", miss);
}

test "getvar_reads_a_numeric_value_as_a_number_so_a_stored_007_renders_as_7" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);
    try chat.set(testing.allocator, "n", "007");
    try chat.set(testing.allocator, "f", "7.50");
    try chat.set(testing.allocator, "s", "7 lamps");

    const n = (try resolve(testing.allocator, "getvar::n", .{ .chat = &chat })).?;
    defer testing.allocator.free(n);
    const f = (try resolve(testing.allocator, "getvar::f", .{ .chat = &chat })).?;
    defer testing.allocator.free(f);
    const s = (try resolve(testing.allocator, "getvar::s", .{ .chat = &chat })).?;
    defer testing.allocator.free(s);

    try testing.expectEqualStrings("7", n);
    try testing.expectEqualStrings("7.5", f);
    try testing.expectEqualStrings("7 lamps", s);
}

test "setvar_stores_the_value_renders_nothing_and_marks_the_store_dirty" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);

    const out = (try resolve(testing.allocator, "setvar::lamp::lit", .{ .chat = &chat })).?;
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("", out);
    try testing.expectEqualStrings("lit", chat.getRaw("lamp").?);
    try testing.expect(chat.dirty);
}

test "a_read_only_pass_leaves_the_store_clean_so_nothing_is_persisted" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);
    try chat.set(testing.allocator, "mood", "wary");
    chat.dirty = false;

    const out = (try resolve(testing.allocator, "getvar::mood", .{ .chat = &chat })).?;
    defer testing.allocator.free(out);

    try testing.expect(!chat.dirty);
}

test "incvar_and_decvar_render_the_new_count_and_start_from_zero" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);

    const first = (try resolve(testing.allocator, "incvar::turns", .{ .chat = &chat })).?;
    defer testing.allocator.free(first);
    const second = (try resolve(testing.allocator, "incvar::turns", .{ .chat = &chat })).?;
    defer testing.allocator.free(second);
    const back = (try resolve(testing.allocator, "decvar::turns", .{ .chat = &chat })).?;
    defer testing.allocator.free(back);

    try testing.expectEqualStrings("1", first);
    try testing.expectEqualStrings("2", second);
    try testing.expectEqualStrings("1", back);
    try testing.expectEqualStrings("1", chat.getRaw("turns").?);
}

test "addvar_adds_numbers_but_concatenates_text" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);
    try chat.set(testing.allocator, "count", "5");
    try chat.set(testing.allocator, "note", "dusk");

    const added = (try resolve(testing.allocator, "addvar::count::3", .{ .chat = &chat })).?;
    defer testing.allocator.free(added);
    const joined = (try resolve(testing.allocator, "addvar::note::fall", .{ .chat = &chat })).?;
    defer testing.allocator.free(joined);

    try testing.expectEqualStrings("", added);
    try testing.expectEqualStrings("", joined);
    try testing.expectEqualStrings("8", chat.getRaw("count").?);
    try testing.expectEqualStrings("duskfall", chat.getRaw("note").?);
}

test "addvar_pushes_onto_a_stored_json_array" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);
    try chat.set(testing.allocator, "seen", "[\"owl\"]");

    const out = (try resolve(testing.allocator, "addvar::seen::fox", .{ .chat = &chat })).?;
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("[\"owl\",\"fox\"]", chat.getRaw("seen").?);
}

test "the_global_twins_touch_the_global_store_and_leave_the_chat_one_alone" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);
    var global: Store = .{};
    defer global.deinit(testing.allocator);

    const set = (try resolve(testing.allocator, "setglobalvar::era::third", .{ .chat = &chat, .global = &global })).?;
    defer testing.allocator.free(set);
    const got = (try resolve(testing.allocator, "getglobalvar::era", .{ .chat = &chat, .global = &global })).?;
    defer testing.allocator.free(got);

    try testing.expectEqualStrings("third", got);
    try testing.expect(global.dirty);
    try testing.expect(!chat.dirty);
    try testing.expect(chat.getRaw("era") == null);
}

test "a_pass_with_no_store_leaves_the_macro_unresolved_rather_than_inventing_a_value" {
    try testing.expect((try resolve(testing.allocator, "getvar::mood", .{})) == null);
    try testing.expect((try resolve(testing.allocator, "setvar::mood::wary", .{})) == null);
}

test "a_macro_that_is_not_a_variable_macro_falls_through" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);

    try testing.expect((try resolve(testing.allocator, "char", .{ .chat = &chat })) == null);
    try testing.expect((try resolve(testing.allocator, "getvarnot::x", .{ .chat = &chat })) == null);
    try testing.expect((try resolve(testing.allocator, "getvar::", .{ .chat = &chat })) == null);
}

fn setAddGetRoundTrip(alloc: Allocator) !void {
    var chat: Store = .{};
    defer chat.deinit(alloc);
    for ([_][]const u8{ "setvar::count::5", "addvar::count::3", "incvar::count", "getvar::count" }) |body| {
        const out = (try resolve(alloc, body, .{ .chat = &chat })).?;
        alloc.free(out);
    }
    try testing.expectEqualStrings("9", chat.getRaw("count").?);
}

test "every_allocation_failure_along_a_set_add_get_sequence_leaks_nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, setAddGetRoundTrip, .{});
}

test "setvar_replaces_a_value_without_leaking_the_old_one" {
    var chat: Store = .{};
    defer chat.deinit(testing.allocator);

    for (0..3) |_| {
        const out = (try resolve(testing.allocator, "setvar::lamp::lit", .{ .chat = &chat })).?;
        testing.allocator.free(out);
    }

    try testing.expectEqualStrings("lit", chat.getRaw("lamp").?);
    try testing.expectEqual(@as(usize, 1), chat.map.count());
}
