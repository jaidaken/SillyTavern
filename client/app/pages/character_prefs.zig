//! Character-list preferences: which sort order the list opens in.
//!
//! Two channels, exactly as the reading prefs do it (reading_prefs.zig): localStorage is the READ
//! path (applied before the first list paint, no round-trip), and the account settings blob is the
//! durable copy, written through reading_prefs' ONE debounced saver via mergeCharPrefs. A second
//! read-modify-write saver would clobber the blob, so this module owns no fetch at all.
//!
//! Default is `.recent`: the list exists to resume a conversation, and alphabetical order buries the
//! character you spoke to an hour ago behind everyone whose name starts with A.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const cv = @import("./character_view.zig");
const char_store = @import("./character_store.zig");
const reading_prefs = @import("./reading_prefs.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.chars);

const sort_ls_key = "st-char-sort";

var hydrated = false;

fn localStorage() ?js.Object {
    if (zx.platform.role != .client) return null;
    return js.global.get(js.Object, "localStorage") catch {
        log.warn("localStorage unavailable: character sort not persisted", .{});
        return null;
    };
}

/// Caller frees. An absent or empty value reads as null so the caller falls back to the default.
fn getItem(a: std.mem.Allocator, key: []const u8) ?[]u8 {
    const ls = localStorage() orelse return null;
    defer ls.deinit();
    const raw = ls.callAlloc(?js.String, a, "getItem", .{js.string(key)}) catch return null;
    const value = raw orelse return null;
    if (value.len == 0) {
        a.free(value);
        return null;
    }
    return value;
}

fn setItem(key: []const u8, value: []const u8) void {
    const ls = localStorage() orelse return;
    defer ls.deinit();
    ls.call(void, "setItem", .{ js.string(key), js.string(value) }) catch {
        log.warn("localStorage write refused: {s}", .{key});
    };
}

/// The persisted sort, or the View default when nothing is stored (or the stored name is stale after
/// a SortKey rename).
pub fn storedSort() cv.SortKey {
    const stored = getItem(alloc, sort_ls_key) orelse return cv.View.default_sort;
    defer alloc.free(stored);
    return std.meta.stringToEnum(cv.SortKey, stored) orelse cv.View.default_sort;
}

/// Apply the persisted sort to the global view, once per session. Called at the top of the list and
/// toolbar renders rather than from boot, so no hot-file wiring is needed: whichever paints first
/// hydrates, and the recompute lands before this render reads `result`.
pub fn ensureHydrated() void {
    if (zx.platform.role != .client or hydrated) return;
    hydrated = true;
    const key = storedSort();
    if (key == cv.global.sort) return;
    cv.global.setSort(key);
    cv.global.compute(char_store.slice()) catch |err| {
        log.warn("character sort hydrate: recompute failed: {s}", .{@errorName(err)});
        return;
    };
    log.debug("character sort hydrated: {s}", .{@tagName(key)});
}

/// Set the sort, persist it, and queue the account save. The caller recomputes and re-renders (it
/// owns the region bump).
pub fn setSort(key: cv.SortKey) void {
    cv.global.setSort(key);
    if (zx.platform.role != .client) return;
    hydrated = true;
    setItem(sort_ls_key, @tagName(key));
    reading_prefs.scheduleSave();
}

/// Write the character-list prefs into the settings object reading_prefs is about to save. Called
/// from reading_prefs.mergedSettings on every save, so this rides the single saver.
pub fn mergeCharPrefs(a: std.mem.Allocator, root_obj: *std.json.ObjectMap) !void {
    var prefs: std.json.ObjectMap = .empty;
    try prefs.put(a, "sort", .{ .string = try a.dupe(u8, @tagName(cv.global.sort)) });
    try root_obj.put(a, "clientCharPrefs", .{ .object = prefs });
}
