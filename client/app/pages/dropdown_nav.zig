//! Pure list-navigation logic for the styled dropdown (dropdown.zx). zx-free so it joins the native
//! `zig build test` aggregator (ZX5): the DOM handlers live in the .zx, this holds only the index
//! math and value/label resolution, which is what needs proving.

const std = @import("std");

pub const Option = struct {
    value: []const u8,
    label: []const u8,
};

/// Index of the first option whose value equals `value`, or null when none matches.
pub fn indexOfValue(options: []const Option, value: []const u8) ?usize {
    for (options, 0..) |opt, i| {
        if (std.mem.eql(u8, opt.value, value)) return i;
    }
    return null;
}

/// The selected option's label, or `placeholder` when the value matches no option (or the list is
/// empty). The button face reads from here, so a stale value never blanks the control.
pub fn selectedLabel(options: []const Option, value: []const u8, placeholder: []const u8) []const u8 {
    if (indexOfValue(options, value)) |i| return options[i].label;
    return placeholder;
}

pub const Nav = enum { down, up, home, end };

/// Next keyboard-active index after a navigation key, wrapping at both ends (the listbox convention:
/// Down past the last lands on the first, Up past the first lands on the last). An empty list stays
/// at 0. `active` at or past `len` is treated as the last valid index before moving.
pub fn move(active: usize, len: usize, nav: Nav) usize {
    if (len == 0) return 0;
    const cur = @min(active, len - 1);
    return switch (nav) {
        .home => 0,
        .end => len - 1,
        .down => if (cur + 1 >= len) 0 else cur + 1,
        .up => if (cur == 0) len - 1 else cur - 1,
    };
}

const t = std.testing;

const fruit = [_]Option{
    .{ .value = "a", .label = "Apple" },
    .{ .value = "b", .label = "Banana" },
    .{ .value = "c", .label = "Cherry" },
};

test "indexOfValue finds a present value and rejects an absent one" {
    try t.expectEqual(@as(?usize, 0), indexOfValue(&fruit, "a"));
    try t.expectEqual(@as(?usize, 2), indexOfValue(&fruit, "c"));
    try t.expectEqual(@as(?usize, null), indexOfValue(&fruit, "z"));
    try t.expectEqual(@as(?usize, null), indexOfValue(&[_]Option{}, "a"));
}

test "selectedLabel returns the matched label else the placeholder" {
    try t.expectEqualStrings("Banana", selectedLabel(&fruit, "b", "Pick one"));
    try t.expectEqualStrings("Pick one", selectedLabel(&fruit, "z", "Pick one"));
    try t.expectEqualStrings("Pick one", selectedLabel(&[_]Option{}, "a", "Pick one"));
}

test "move wraps down and up and honors home and end" {
    try t.expectEqual(@as(usize, 1), move(0, 3, .down));
    try t.expectEqual(@as(usize, 0), move(2, 3, .down));
    try t.expectEqual(@as(usize, 1), move(2, 3, .up));
    try t.expectEqual(@as(usize, 2), move(0, 3, .up));
    try t.expectEqual(@as(usize, 0), move(2, 3, .home));
    try t.expectEqual(@as(usize, 2), move(0, 3, .end));
}

test "move clamps an out-of-range active index before stepping" {
    try t.expectEqual(@as(usize, 0), move(9, 3, .down));
    try t.expectEqual(@as(usize, 1), move(9, 3, .up));
}

test "move on an empty list stays at zero for every key" {
    for ([_]Nav{ .down, .up, .home, .end }) |nav| {
        try t.expectEqual(@as(usize, 0), move(0, 0, nav));
    }
}

test "a full cycle of down returns to the start" {
    var i: usize = 0;
    for (0..fruit.len) |_| i = move(i, fruit.len, .down);
    try t.expectEqual(@as(usize, 0), i);
}
