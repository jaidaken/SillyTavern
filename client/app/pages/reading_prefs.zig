const std = @import("std");
const builtin = @import("builtin");
const zx = @import("zx");

const is_wasm = builtin.target.cpu.arch == .wasm32;

const READING_KEYS = [_][]const u8{
    "size", "measure", "lh", "justify", "indent", "theme", "tab", "avatars",
};

fn defaultForKey(key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "size")) return "m";
    if (std.mem.eql(u8, key, "measure")) return "normal";
    if (std.mem.eql(u8, key, "lh")) return "normal";
    if (std.mem.eql(u8, key, "justify")) return "on";
    if (std.mem.eql(u8, key, "indent")) return "novel";
    if (std.mem.eql(u8, key, "theme")) return "dark";
    if (std.mem.eql(u8, key, "tab")) return "reading";
    if (std.mem.eql(u8, key, "avatars")) return "on";
    return "m";
}

fn prefixedKey(comptime prefix: []const u8, key: []const u8, buf: *[64]u8) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..key.len], key);
    return buf[0 .. prefix.len + key.len];
}

fn localStorageKey(key: []const u8, buf: *[64]u8) []const u8 {
    return prefixedKey("st-reading-", key, buf);
}

fn dataAttrKey(key: []const u8, buf: *[64]u8) []const u8 {
    return prefixedKey("data-reading-", key, buf);
}

fn getLocalStorage() ?zx.client.js.Object {
    if (!is_wasm) return null;
    const ls = zx.client.js.global.get(zx.client.js.Object, "localStorage") catch return null;
    return ls;
}

fn getChatRoot() ?zx.client.js.Object {
    if (!is_wasm) return null;
    const doc = zx.client.js.global.get(zx.client.js.Object, "document") catch return null;
    const getElementById = doc.get(zx.client.js.Object, "getElementById") catch return null;
    return getElementById.call(zx.client.js.Object, "", .{zx.client.js.string("chat-root")}) catch return null;
}

/// Apply all reading preferences from localStorage + defaults to the chat-root element.
pub fn applyAll() void {
    if (!is_wasm) return;
    inline for (READING_KEYS) |key| {
        const default_val = defaultForKey(key);
        var kbuf: [64]u8 = undefined;
        var dbuf: [64]u8 = undefined;
        const ls_key = localStorageKey(key, &kbuf);
        const attr_name = dataAttrKey(key, &dbuf);

        const ls = getLocalStorage() orelse return;
        const stored = ls.callAlloc(zx.client.js.String, zx.allocator, "getItem", .{zx.client.js.string(ls_key)}) catch return;
        const val = if (stored.len > 0) stored else default_val;

        const root = getChatRoot() orelse return;
        root.call(void, "setAttribute", .{ zx.client.js.string(attr_name), zx.client.js.string(val) }) catch return;
    }
}

var save_timer: u32 = 0;
const SAVE_MS = 3000;

/// Synchronise aria-pressed on all [data-reading-set] buttons to match chat-root state.
pub fn syncAria() void {
    if (!is_wasm) return;
    const root = getChatRoot() orelse return;
    const querySelectorAll = root.get(zx.client.js.Object, "querySelectorAll") catch return;
    const list = querySelectorAll.call(zx.client.js.Object, "querySelectorAll", .{zx.client.js.string("[data-reading-set]")}) catch return;
    const len = list.get(u32, "length") catch return;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const item = list.call(zx.client.js.Object, "item", .{i}) catch {
            i += 1;
            continue;
        };
        // Check if item is an object (NodeList items should be Elements)
        if (item.value.typeOf() != .object) {
            i += 1;
            continue;
        }
        const dataset = item.get(zx.client.js.Object, "dataset") catch {
            i += 1;
            continue;
        };
        const set_key = dataset.getAlloc(zx.client.js.String, zx.allocator, "readingSet") catch {
            i += 1;
            continue;
        };
        const set_val = dataset.getAlloc(zx.client.js.String, zx.allocator, "readingVal") catch {
            zx.allocator.free(set_key);
            i += 1;
            continue;
        };
        defer zx.allocator.free(set_key);
        defer zx.allocator.free(set_val);
        var abuf: [64]u8 = undefined;
        const attr_name = dataAttrKey(set_key, &abuf);
        const on_val = root.getAlloc(zx.client.js.String, zx.allocator, attr_name) catch {
            i += 1;
            continue;
        };
        const on = std.mem.eql(u8, on_val, set_val);
        item.call(void, "setAttribute", .{ zx.client.js.string("aria-pressed"), zx.client.js.string(if (on) "true" else "false") }) catch return;
    }
}

/// Handle a [data-reading-set] click. key and val are the data-reading-set and data-reading-val
/// of the clicked button. Updates localStorage, DOM attributes, clears custom measure if
/// the measure preset was clicked, syncs ARIA, and starts a debounced server save.
pub fn handleClick(key: []const u8, val: []const u8) void {
    if (!is_wasm) return;

    var kbuf: [64]u8 = undefined;
    var dbuf: [64]u8 = undefined;
    const ls_key = localStorageKey(key, &kbuf);
    const attr_name = dataAttrKey(key, &dbuf);

    const ls = getLocalStorage() orelse return;
    ls.call(void, "setItem", .{ zx.client.js.string(ls_key), zx.client.js.string(val) }) catch return;

    const root = getChatRoot() orelse return;
    root.call(void, "setAttribute", .{ zx.client.js.string(attr_name), zx.client.js.string(val) }) catch return;

    if (std.mem.eql(u8, key, "measure")) {
        const root2 = getChatRoot() orelse return;
        const style = root2.get(zx.client.js.Object, "style") catch return;
        style.call(void, "removeProperty", .{zx.client.js.string("--reading-measure")}) catch return;
        ls.call(void, "removeItem", .{zx.client.js.string("st-reading-custom-measure")}) catch return;
    }

    syncAria();

    if (save_timer != 0) {
        const global = zx.client.js.global;
        global.call(void, "clearTimeout", .{save_timer}) catch return;
    }
    const global = zx.client.js.global;
    save_timer = global.call(u32, "setTimeout", .{SAVE_MS}) catch return;
}

/// Called by the bridge when the debounced save timer fires.
pub fn onSaveTimeout() void {
    save_timer = 0;
    const global = zx.client.js.global;
    global.call(void, "__st_reading_save_now", .{}) catch return;
}

/// Direct save (no debounce) for resize handlers.
pub fn saveNow() void {
    const global = zx.client.js.global;
    global.call(void, "__st_reading_save_now", .{}) catch return;
}
