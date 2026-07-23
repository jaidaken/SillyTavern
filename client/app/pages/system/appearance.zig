//! Global appearance: SmartTheme-style chrome colour overrides and a free-form custom-CSS box. The
//! sibling of reading_prefs.zig (which owns the CHAT reading surface); this owns the CHROME theme.
//!
//! Two channels, both persisted the same way reading prefs are: localStorage (`st-appearance-*`,
//! the fast source that drives the UI before any network round trip) plus the account settings blob
//! (`clientAppearance`, the durable target, written through reading_prefs' single debounced saver so
//! two independent full-replace saves can never clobber the blob).
//!
//! 1. Theme vars: a curated set of chrome tokens (accent/bg/surface) the user recolours. Each is set
//!    as an inline custom property on the document root, which beats the @theme :root declaration. A
//!    reading theme (sepia/paper) repoints its own tokens scoped to #chat, so the reading surface
//!    stays governed by the reading panel, not this one.
//! 2. Custom CSS: the user's own stylesheet, injected into one <style> element. INVARIANT 6: it is
//!    wrapped in `@scope (:root) to (.mes_text)`, so a user rule can never subject-match the
//!    sanitized message body (.mes_text and its subtree are the scope limit, excluded from scope).
//!    A browser without @scope drops the whole block, so the box fails closed (no styling), never
//!    open. Chrome is fully reachable; message content is not.
//!
//! zx-importing, so it is browser-verified through the interaction gate (ZX5), not `zig build test`.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const char_store = @import("../cast/character_store.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.panels);

const Var = struct { name: []const u8, label: []const u8, prop: []const u8, default: []const u8 };

/// The chrome tokens the appearance panel recolours. name = the control's data-appearance-var and
/// the `st-appearance-<name>` localStorage suffix; label = the row's display name; prop = the CSS
/// custom property it overrides; default = a hex approximation of the oklch token, the colour
/// picker's initial swatch when unset (the picker cannot render oklch). --color-text is deliberately
/// absent: message-body text colour is a reading pref, not chrome.
pub const vars = [_]Var{
    .{ .name = "accent", .label = "Accent", .prop = "--color-accent", .default = "#d9a441" },
    .{ .name = "bg", .label = "Background", .prop = "--color-bg", .default = "#26221d" },
    .{ .name = "surface", .label = "Surface", .prop = "--color-surface", .default = "#2e2924" },
};

/// A slice view of `vars` for `{for}` in the panel (ZX1: the loop target must be a slice).
pub const vars_slice: []const Var = &vars;

/// The localStorage key for the custom-CSS text. Also read by reading_prefs.mergedSettings so the
/// text rides the same account-settings save as the reading prefs.
pub const css_key = "st-appearance-css";

const style_id = "st-user-css";

// ---- localStorage (jsz two-step per T2: window things come off js.global) ---------------------

fn localStorage() ?js.Object {
    if (zx.platform.role != .client) return null;
    return js.global.get(js.Object, "localStorage") catch {
        log.warn("localStorage unavailable", .{});
        return null;
    };
}

/// Caller frees. An absent or empty value reads as null so callers fall back to the token default.
/// The comptime guard prunes the jsz body from the server build (SettingsBody renders on SSR and
/// calls this via pickerValue/storedCss, where js.Object is void; ZX2).
fn getItem(a: std.mem.Allocator, key: []const u8) ?[]u8 {
    if (zx.platform.role != .client) return null;
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
    if (zx.platform.role != .client) return;
    const ls = localStorage() orelse return;
    defer ls.deinit();
    ls.call(void, "setItem", .{ js.string(key), js.string(value) }) catch {
        log.warn("localStorage write refused: {s}", .{key});
    };
}

fn removeItem(key: []const u8) void {
    if (zx.platform.role != .client) return;
    const ls = localStorage() orelse return;
    defer ls.deinit();
    ls.call(void, "removeItem", .{js.string(key)}) catch {};
}

// ---- the document-root custom properties the chrome reads --------------------------------------

/// The style object of the document root (:root / <html>). Caller deinits. The intermediate document
/// and documentElement handles are independent of the returned style handle, so freeing them here is
/// safe.
fn rootStyle() ?js.Object {
    if (zx.platform.role != .client) return null;
    const doc = js.global.get(js.Object, "document") catch return null;
    defer doc.deinit();
    const de = doc.get(js.Object, "documentElement") catch return null;
    defer de.deinit();
    return de.get(js.Object, "style") catch null;
}

fn setProp(prop: []const u8, value: []const u8) void {
    if (zx.platform.role != .client) return;
    const style = rootStyle() orelse return;
    defer style.deinit();
    style.call(void, "setProperty", .{ js.string(prop), js.string(value) }) catch {
        log.warn("could not set {s}", .{prop});
    };
}

/// removeProperty answers with the OLD value, so `void` made every call return InvalidType into that
/// empty catch. The property still went (the JS ran; only the return conversion failed), which is why
/// nothing looked wrong: measured, one Reset click pushed jsz slot 378 into the free list five times.
fn removeProp(prop: []const u8) void {
    if (zx.platform.role != .client) return;
    const style = rootStyle() orelse return;
    defer style.deinit();
    const ret = style.call(?js.Value, "removeProperty", .{js.string(prop)}) catch return;
    if (ret) |r| r.deinit();
}

fn propFor(name: []const u8) ?[]const u8 {
    inline for (vars) |v| {
        if (std.mem.eql(u8, name, v.name)) return v.prop;
    }
    return null;
}

// ---- boot apply -------------------------------------------------------------------------------

/// Every stored appearance override onto the document root, and the custom CSS into its <style>.
/// Called at boot from bridge.bootInit, so overrides land before the first paint. An absent var is
/// left untouched: the @theme default stands rather than being pinned to a stored copy.
pub fn applyAll() void {
    if (zx.platform.role != .client) return;
    inline for (vars) |v| {
        const stored = getItem(alloc, "st-appearance-" ++ v.name);
        defer if (stored) |s| alloc.free(s);
        if (stored) |val| setProp(v.prop, val);
    }
    const css = getItem(alloc, css_key);
    defer if (css) |c| alloc.free(c);
    injectCustomCss(if (css) |c| c else "");
    log.debug("appearance applied", .{});
}

// ---- render helpers (the controls' initial values) --------------------------------------------

/// The colour picker's initial swatch for `name`: the user's stored override, else the token's hex
/// default. Allocated on `a` (the render allocator); an unknown name yields "#000000".
pub fn pickerValue(a: std.mem.Allocator, name: []const u8) []const u8 {
    var buf: [48]u8 = undefined;
    const ls_key = std.fmt.bufPrint(&buf, "st-appearance-{s}", .{name}) catch return "#000000";
    if (getItem(a, ls_key)) |val| return val;
    inline for (vars) |v| {
        if (std.mem.eql(u8, name, v.name)) return v.default;
    }
    return "#000000";
}

/// The custom-CSS textarea's stored content, or "" when unset. Allocated on `a`.
pub fn storedCss(a: std.mem.Allocator) []const u8 {
    return getItem(a, css_key) orelse "";
}

// ---- the click / input paths ------------------------------------------------------------------

/// A theme var was recoloured: persist it and apply it. `name` is the control's data-appearance-var,
/// `value` a CSS colour. An empty value clears the override so the token default returns. The caller
/// (settings_body) queues the debounced save.
pub fn setVar(name: []const u8, value: []const u8) void {
    if (zx.platform.role != .client) return;
    const prop = propFor(name) orelse {
        log.warn("appearance: unknown var {s}", .{name});
        return;
    };
    var buf: [48]u8 = undefined;
    const ls_key = std.fmt.bufPrint(&buf, "st-appearance-{s}", .{name}) catch return;
    if (value.len == 0) {
        removeItem(ls_key);
        removeProp(prop);
    } else {
        setItem(ls_key, value);
        setProp(prop, value);
    }
    log.debug("appearance {s} = {s}", .{ name, value });
}

/// Clear every theme var override so the tokens revert to the Scriptorium defaults. Leaves the
/// custom CSS alone. The caller queues the save.
pub fn resetVars() void {
    if (zx.platform.role != .client) return;
    inline for (vars) |v| {
        removeItem("st-appearance-" ++ v.name);
        removeProp(v.prop);
    }
    log.debug("appearance vars reset", .{});
}

/// The custom-CSS text changed: persist it and re-inject. The caller queues the save.
pub fn setCustomCss(text: []const u8) void {
    if (zx.platform.role != .client) return;
    if (text.len == 0) removeItem(css_key) else setItem(css_key, text);
    injectCustomCss(text);
}

// ---- the injected <style> ---------------------------------------------------------------------

/// Our single <style> element, created once in <head> and reused. A persistent DOM node, so the
/// handle is cached for the process lifetime rather than re-resolved each edit.
var style_el: ?js.Object = null;

fn styleEl() ?js.Object {
    if (zx.platform.role != .client) return null;
    if (style_el) |e| return e;
    const doc = js.global.get(js.Object, "document") catch return null;
    defer doc.deinit();
    const el = doc.call(js.Object, "createElement", .{js.string("style")}) catch return null;
    el.call(void, "setAttribute", .{ js.string("id"), js.string(style_id) }) catch {};
    const head = doc.get(js.Object, "head") catch {
        el.deinit();
        return null;
    };
    defer head.deinit();
    _ = head.call(js.Object, "appendChild", .{el}) catch {
        el.deinit();
        return null;
    };
    style_el = el;
    return el;
}

/// INVARIANT 6: the user's CSS is wrapped in `@scope (:root) to (.mes_text)` before it reaches the
/// DOM, so no rule in it can subject-match the sanitized message body. Empty text clears the sheet.
fn injectCustomCss(text: []const u8) void {
    if (zx.platform.role != .client) return;
    const el = styleEl() orelse return;
    if (text.len == 0) {
        el.set("textContent", js.string("")) catch {};
        return;
    }
    const wrapped = std.fmt.allocPrint(
        alloc,
        "@scope (:root) to (.mes_text) {{\n{s}\n}}",
        .{text},
    ) catch return;
    defer alloc.free(wrapped);
    el.set("textContent", js.string(wrapped)) catch {
        log.warn("could not write custom CSS", .{});
    };
}
