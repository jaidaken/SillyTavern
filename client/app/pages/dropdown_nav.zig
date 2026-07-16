//! Pure list-navigation and open-state logic for the styled dropdown (dropdown.zx). zx-free so it
//! joins the native `zig build test` aggregator (ZX5): the DOM handlers live in the .zx, this holds
//! the index math, value/label resolution, and which menu is open, which is what needs proving.
//!
//! The open state lives HERE rather than in dropdown.zx because ui.zig has to read it: a .zig module
//! cannot import a .zx one (the transpiler copies app/pages/*.zig into a cache dir where the .zx
//! sources do not exist), so state parked in the .zx is unreachable to the page-level Escape guard.

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

// App-global open state (ZX4): one dropdown open at a time, keyed by name. The open dropdown's name
// is COPIED into a fixed buffer, never aliased: the name reaching setOpen comes from
// dom_event.datasetUp, an owned heap string the click branch frees on return, so storing the slice
// would be a use-after-free (the freed bytes get reused mid-session and the key corrupts).
var open_buf: [96]u8 = undefined;
var open_len: usize = 0;

/// The longest dropdown name the open state can hold. A name is a baked per-dropdown constant, so
/// this bound is a build-time fact, not a runtime limit users can reach.
pub const max_name_len = open_buf.len;

/// The open dropdown's name, or null when every menu is closed. Borrowed from the state buffer;
/// it stays valid until the next setOpen/closeMenu.
pub fn openName() ?[]const u8 {
    return if (open_len == 0) null else open_buf[0..open_len];
}

/// True when this specific dropdown's menu is open.
pub fn isOpen(name: []const u8) bool {
    return open_len > 0 and std.mem.eql(u8, open_buf[0..open_len], name);
}

/// True when ANY dropdown's menu is open. The page-level Escape guard (ui.onPageKey) reads this to
/// stand down while a menu owns the key, which is why the state cannot live in the .zx.
pub fn isOpenAny() bool {
    return open_len > 0;
}

/// Record `name` as the open menu, copying it into the state buffer. Returns false and leaves the
/// state untouched when the name does not fit: a truncated copy would never compare equal in isOpen,
/// so the menu would read as closed while isOpenAny stayed true and swallowed every page Escape.
pub fn setOpen(name: []const u8) bool {
    if (name.len == 0 or name.len > open_buf.len) return false;
    @memcpy(open_buf[0..name.len], name);
    open_len = name.len;
    return true;
}

pub fn closeMenu() void {
    open_len = 0;
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

test "no menu is open until one is set" {
    closeMenu();
    try t.expect(!isOpenAny());
    try t.expectEqual(@as(?[]const u8, null), openName());
    try t.expect(!isOpen("char-sort"));
}

test "setOpen marks that menu open and no other" {
    closeMenu();
    try t.expect(setOpen("char-sort"));
    try t.expect(isOpenAny());
    try t.expect(isOpen("char-sort"));
    try t.expect(!isOpen("char-pagesize"));
    try t.expectEqualStrings("char-sort", openName().?);
}

test "opening a second menu replaces the first" {
    closeMenu();
    try t.expect(setOpen("char-sort"));
    try t.expect(setOpen("char-pagesize"));
    try t.expect(!isOpen("char-sort"));
    try t.expect(isOpen("char-pagesize"));
    try t.expectEqualStrings("char-pagesize", openName().?);
}

test "closeMenu clears the open state for every reader" {
    closeMenu();
    try t.expect(setOpen("char-sort"));
    closeMenu();
    try t.expect(!isOpenAny());
    try t.expect(!isOpen("char-sort"));
    try t.expectEqual(@as(?[]const u8, null), openName());
}

test "a shorter name after a longer one does not read the stale tail" {
    closeMenu();
    try t.expect(setOpen("char-pagesize"));
    try t.expect(setOpen("api"));
    try t.expectEqualStrings("api", openName().?);
    try t.expect(isOpen("api"));
    try t.expect(!isOpen("char-pagesize"));
}

test "setOpen copies the name instead of aliasing the caller's buffer" {
    closeMenu();
    var caller_owned = [_]u8{ 'c', 'h', 'a', 'r', '-', 's', 'o', 'r', 't' };
    try t.expect(setOpen(&caller_owned));
    @memset(&caller_owned, 0xAA);
    try t.expectEqualStrings("char-sort", openName().?);
    try t.expect(isOpen("char-sort"));
}

test "setOpen rejects a name too long for the buffer and stays closed" {
    closeMenu();
    const too_long = "d" ** (max_name_len + 1);
    try t.expect(!setOpen(too_long));
    try t.expect(!isOpenAny());
    try t.expect(!isOpen(too_long));
}

test "setOpen accepts a name that exactly fills the buffer" {
    closeMenu();
    const exact = "d" ** max_name_len;
    try t.expect(setOpen(exact));
    try t.expect(isOpen(exact));
    try t.expectEqualStrings(exact, openName().?);
    closeMenu();
}

test "setOpen rejects an empty name and leaves an open menu untouched" {
    closeMenu();
    try t.expect(setOpen("char-sort"));
    try t.expect(!setOpen(""));
    try t.expect(isOpen("char-sort"));
    closeMenu();
}
