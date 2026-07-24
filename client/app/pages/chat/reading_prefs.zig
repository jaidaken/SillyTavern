//! Reading preferences: the single owner of the reading surface state (text size, line width, line
//! height, justify, paragraph style, theme, tab, avatars). One click path, one boot path, one save.
//!
//! Each preference lives in three places and this module keeps them in step: localStorage
//! (`st-reading-<key>`, survives a reload before any network round trip), a `data-reading-<key>`
//! attribute on #chat-root (what the CSS actually reads), and the account settings on the server
//! (`clientReadingPrefs`, written through net.zig behind a debounce so a burst of clicks is one
//! POST). aria-pressed on every [data-reading-set] control is synced from the DOM attributes after
//! each change, which is why the buttons need no reactive state of their own.
//!
//! zx-importing, so it is browser-verified through the interaction gate (ZX5), not `zig build
//! test`; the pure spec parse it leans on lives in char_data.zig.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const net = @import("../platform/net.zig");
const data = @import("../cast/char_data.zig");
const char_store = @import("../cast/character_store.zig");
const dom_event = @import("../platform/dom_event.zig");
const appearance = @import("../system/appearance.zig");
const backgrounds = @import("../system/backgrounds.zig");
const character_prefs = @import("../cast/character_prefs.zig");
const config_state = @import("../system/config_state.zig");
const persona_actions = @import("../cast/persona_actions.zig");
const wi_actions = @import("../setup/world_info_actions.zig"); // w3-wi
const tag_store = @import("../cast/tag_store.zig"); // w3-reason 3d tags

const alloc = char_store.page_gpa;
const log = std.log.scoped(.panels);

/// The controls carry these as data-reading-set. "tab" is one of them: the settings tabs are
/// reading state too (which sub-panel shows), keyed by CSS off the same attribute.
pub const keys = [_][]const u8{ "size", "measure", "lh", "justify", "indent", "font", "theme", "tab", "avatars" };

/// The pixel width the reading-width drag persists (the drag gesture lives in this module, driven by
/// the pointer events the door delegates via patch-door D5). A measure PRESET click drops it, inline
/// custom property and stored pixels together, so the preset governs again; the server copy carries
/// it so the width follows the account.
const measure_px_key = "st-reading-measurepx";

/// The reading-width drag floor. Below this the column is unreadably narrow; the drag and the
/// keyboard nudges both clamp here, and a stored width below it is ignored at boot.
const measure_min_w: f64 = 320;

fn defaultFor(comptime key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "size")) return "m";
    if (std.mem.eql(u8, key, "measure")) return "normal";
    if (std.mem.eql(u8, key, "lh")) return "normal";
    if (std.mem.eql(u8, key, "justify")) return "on";
    if (std.mem.eql(u8, key, "indent")) return "chat";
    if (std.mem.eql(u8, key, "font")) return "serif";
    if (std.mem.eql(u8, key, "theme")) return "dark";
    if (std.mem.eql(u8, key, "tab")) return "reading";
    if (std.mem.eql(u8, key, "avatars")) return "on";
    return "m";
}

// ---- localStorage (jsz, two-step per T2: window things come off js.global) ------------------

fn localStorage() ?js.Object {
    if (zx.platform.role != .client) return null;
    return js.global.get(js.Object, "localStorage") catch {
        log.warn("localStorage unavailable", .{});
        return null;
    };
}

/// Caller frees. An absent key and an empty value both read as null, so callers fall back to the
/// default rather than writing an empty attribute.
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

fn removeItem(key: []const u8) void {
    const ls = localStorage() orelse return;
    defer ls.deinit();
    ls.call(void, "removeItem", .{js.string(key)}) catch {};
}

// ---- the chat-root attributes the CSS reads ---------------------------------------------------

fn chatRoot() ?zx.client.Document.HTMLElement {
    const root = dom_event.elementById(alloc, "chat-root") orelse {
        log.warn("#chat-root missing: reading prefs not applied", .{});
        return null;
    };
    return root;
}

/// "data-reading-<key>" for a runtime key. The comptime paths build the name with `++` instead.
fn attrName(buf: *[48]u8, key: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "data-reading-{s}", .{key}) catch null;
}

// ---- boot apply -------------------------------------------------------------------------------

/// Every preference from localStorage (or its default) onto #chat-root. Called at boot from
/// bridge.bootInit, so persisted prefs land before the first paint of the chat.
pub fn applyAll() void {
    if (zx.platform.role != .client) return;
    const root = chatRoot() orelse return;
    defer root.deinit();
    inline for (keys) |key| {
        const stored = getItem(alloc, "st-reading-" ++ key);
        defer if (stored) |s| alloc.free(s);
        root.setAttribute("data-reading-" ++ key, stored orelse defaultFor(key));
    }
    // The persisted drag width is a pixel value, not a preset, so it rides its own key and lands as
    // the inline --reading-measure override (which beats the preset rules) before the first paint.
    if (getItem(alloc, measure_px_key)) |px| {
        defer alloc.free(px);
        const n = std.fmt.parseInt(i64, px, 10) catch 0;
        if (@as(f64, @floatFromInt(n)) >= measure_min_w) setMeasure(@floatFromInt(n), false);
    }
    log.debug("reading prefs applied", .{});
}

/// aria-pressed on every [data-reading-set] control, from the attributes now on #chat-root. The
/// controls hold no reactive state (the CSS keys off #chat-root), so this is the one place their
/// pressed state is published to assistive tech.
pub fn syncAria() void {
    if (zx.platform.role != .client) return;
    const root = chatRoot() orelse return;
    defer root.deinit();
    const list = root.ref.call(js.Object, "querySelectorAll", .{js.string("[data-reading-set]")}) catch return;
    defer list.deinit();
    const len = list.get(u32, "length") catch return;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const item = list.call(js.Object, "item", .{i}) catch continue;
        defer item.deinit();
        const ds = item.get(js.Object, "dataset") catch continue;
        defer ds.deinit();
        const set_key = ds.getAlloc(js.String, alloc, "readingSet") catch continue;
        defer alloc.free(set_key);
        const set_val = ds.getAlloc(js.String, alloc, "readingVal") catch continue;
        defer alloc.free(set_val);
        var buf: [48]u8 = undefined;
        const attr = attrName(&buf, set_key) orelse continue;
        const current = root.ref.callAlloc(js.String, alloc, "getAttribute", .{js.string(attr)}) catch continue;
        defer alloc.free(current);
        const pressed = std.mem.eql(u8, current, set_val);
        item.call(void, "setAttribute", .{
            js.string("aria-pressed"),
            js.string(if (pressed) "true" else "false"),
        }) catch {};
    }
}

// ---- the click path ---------------------------------------------------------------------------

/// A [data-reading-set] control was activated: persist it, apply it, republish aria, and queue the
/// server save. `key` and `val` are the control's data-reading-set / data-reading-val.
pub fn handleClick(key: []const u8, val: []const u8) void {
    if (zx.platform.role != .client) return;
    var ls_buf: [48]u8 = undefined;
    const ls_key = std.fmt.bufPrint(&ls_buf, "st-reading-{s}", .{key}) catch return;
    var attr_buf: [48]u8 = undefined;
    const attr = attrName(&attr_buf, key) orelse return;

    setItem(ls_key, val);

    const root = chatRoot() orelse return;
    defer root.deinit();
    root.setAttribute(attr, val);

    if (std.mem.eql(u8, key, "measure")) clearMeasureOverride(root);

    syncAria();
    scheduleSave();
    log.debug("reading {s} = {s}", .{ key, val });
}

/// The drag writes --reading-measure inline, which beats the preset rules; picking a preset must
/// therefore drop both the inline property and the persisted pixels.
fn clearMeasureOverride(root: zx.client.Document.HTMLElement) void {
    const style = root.ref.get(js.Object, "style") catch return;
    defer style.deinit();
    // removeProperty hands back the old value, so `void` made every call error into this catch (see
    // appearance.removeProp). The removal itself always landed; the double-free on the way out did not.
    const ret = style.call(?js.Value, "removeProperty", .{js.string("--reading-measure")}) catch null;
    if (ret) |r| r.deinit();
    removeItem(measure_px_key);
}

// ---- the reading-width drag (ziex, client-only; door delegates pointer via patch-door D5) ------

/// Set the inline --reading-measure override on #chat-root, clamped to [320, #chat width - 32].
/// `persist` also writes the pixel width to localStorage; a measure preset click drops both.
fn setMeasure(px: f64, persist: bool) void {
    if (zx.platform.role != .client) return;
    const root = chatRoot() orelse return;
    defer root.deinit();
    var max_w: f64 = 1200;
    if (dom_event.elementById(alloc, "chat")) |chat| {
        defer chat.deinit();
        if (chat.ref.get(f64, "clientWidth")) |cw| {
            max_w = cw - 32;
        } else |_| {}
    }
    const wi: i64 = @intFromFloat(@round(std.math.clamp(px, measure_min_w, max_w)));
    const style = root.ref.get(js.Object, "style") catch return;
    defer style.deinit();
    var buf: [24]u8 = undefined;
    const val = std.fmt.bufPrint(&buf, "{d}px", .{wi}) catch return;
    style.call(void, "setProperty", .{ js.string("--reading-measure"), js.string(val) }) catch {};
    if (persist) {
        var kb: [16]u8 = undefined;
        const ks = std.fmt.bufPrint(&kb, "{d}", .{wi}) catch return;
        setItem(measure_px_key, ks);
    }
}

/// Drop the drag override entirely (inline property + stored pixels), so the measure preset rules
/// govern again. The Home key and a dblclick on the separator both land here.
fn clearMeasure() void {
    if (zx.platform.role != .client) return;
    const root = chatRoot() orelse return;
    defer root.deinit();
    clearMeasureOverride(root);
}

const MeasureDrag = struct { start_x: f64, start_w: f64, handle: js.Object };
var measure_drag: ?MeasureDrag = null;

/// Pointerdown on the .chat-resize separator: capture the start geometry, take pointer capture so the
/// move survives the cursor leaving the handle, and suppress selection.
pub fn onMeasureDown(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return;
    defer target.deinit();
    const handle = (target.call(?js.Object, "closest", .{js.string(".chat-resize")}) catch return) orelse return;
    ev.preventDefault();
    var start_w: f64 = 640;
    if (handle.call(?js.Object, "closest", .{js.string(".chat-inner")}) catch null) |inner| {
        defer inner.deinit();
        if (dom_event.rectWidth(inner)) |w| start_w = w;
    }
    measure_drag = .{ .start_x = dom_event.eventNum(ev, "clientX") orelse 0, .start_w = start_w, .handle = handle };
    dom_event.addClass(handle, "is-dragging");
    if (dom_event.eventNum(ev, "pointerId")) |pid| handle.call(void, "setPointerCapture", .{pid}) catch {};
    dom_event.setBodyUserSelect(true);
    dom_event.setPtrDrag(true);
}

/// Pointermove: centered column, so moving the edge by dx widens the measure by 2dx (not persisted).
pub fn onMeasureMove(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const drag = measure_drag orelse return;
    const cx = dom_event.eventNum(ev, "clientX") orelse return;
    setMeasure(@round(drag.start_w + (cx - drag.start_x) * 2), false);
}

pub fn onMeasureUp(ev: zx.client.Event) void {
    endMeasureDrag(ev);
}

pub fn onMeasureCancel(ev: zx.client.Event) void {
    endMeasureDrag(ev);
}

/// Pointerup/cancel: persist the separator's landed width and clear the drag state.
fn endMeasureDrag(_: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const drag = measure_drag orelse return;
    measure_drag = null;
    defer drag.handle.deinit();
    if (drag.handle.call(?js.Object, "closest", .{js.string(".chat-inner")}) catch null) |inner| {
        defer inner.deinit();
        if (dom_event.rectWidth(inner)) |w| setMeasure(@round(w), true);
    }
    dom_event.removeClass(drag.handle, "is-dragging");
    dom_event.setBodyUserSelect(false);
    dom_event.setPtrDrag(false);
    log.debug("reading width set", .{});
}

/// Keyboard on the focusable separator (WCAG 2.1.1): arrows nudge 16px, Home returns to the preset.
pub fn onMeasureKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return;
    defer target.deinit();
    const handle = (target.call(?js.Object, "closest", .{js.string(".chat-resize")}) catch return) orelse return;
    defer handle.deinit();
    const key = ev.key() orelse return;
    defer zx.allocator.free(key);
    var cur: f64 = 640;
    if (handle.call(?js.Object, "closest", .{js.string(".chat-inner")}) catch null) |inner| {
        defer inner.deinit();
        if (dom_event.rectWidth(inner)) |w| cur = w;
    }
    if (std.mem.eql(u8, key, "ArrowRight") or std.mem.eql(u8, key, "ArrowUp")) {
        setMeasure(@round(cur + 16), true);
        ev.preventDefault();
    } else if (std.mem.eql(u8, key, "ArrowLeft") or std.mem.eql(u8, key, "ArrowDown")) {
        setMeasure(@round(cur - 16), true);
        ev.preventDefault();
    } else if (std.mem.eql(u8, key, "Home")) {
        clearMeasure();
        ev.preventDefault();
    }
}

/// Dblclick on the separator resets the reading width to the preset.
pub fn onMeasureDblclick(_: zx.client.Event) void {
    clearMeasure();
}

// ---- the debounced server save ----------------------------------------------------------------

const save_delay_ms = 3000;

/// ziex exposes setTimeout but no clearTimeout, so the debounce counts instead of cancelling:
/// every click schedules a timer and increments this; each timer decrements it and only the one
/// that finds no newer click pending goes on to save.
var pending_saves: u32 = 0;

/// Queue the debounced account-settings save. Public so appearance.zig routes its own changes
/// through this ONE saver: two independent read-modify-write savers would clobber the settings blob.
pub fn scheduleSave() void {
    pending_saves += 1;
    log.debug("save scheduled, {d} pending", .{pending_saves});
    if (zx.client.setTimeout(onSaveTimeout, save_delay_ms) == null) {
        // Timer registry full (64 slots): save immediately rather than lose the change.
        pending_saves -= 1;
        log.warn("no timer slot for the reading-prefs debounce, saving now", .{});
        saveNow();
    }
}

fn onSaveTimeout() void {
    if (pending_saves > 0) pending_saves -= 1;
    log.debug("save timer fired, {d} still pending", .{pending_saves});
    if (pending_saves != 0) return;
    saveNow();
}

/// Read-modify-write against the account settings: /api/settings/get, merge clientReadingPrefs into
/// whatever is there, /api/settings/save. Merging (not replacing) is the point - the settings blob
/// holds everything else the app owns.
fn saveNow() void {
    if (zx.platform.role != .client) return;
    net.request("/api/settings/get", "{}", 0, onSettingsFetched, .{});
}

fn onSettingsFetched(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (res == null or status < 200 or status >= 300) {
        log.warn("reading prefs save: settings fetch returned {d}", .{status});
        return;
    }
    const parsed = res.?.json(data.SettingsJson) catch {
        log.warn("reading prefs save: settings response is not an object", .{});
        return;
    };
    defer parsed.deinit();
    const body = mergedSettings(parsed.value.settings orelse "{}") catch |err| {
        log.err("reading prefs save: merge failed: {s}", .{@errorName(err)});
        return;
    };
    defer alloc.free(body);
    net.request("/api/settings/save", body, 0, onSettingsSaved, .{});
}

fn onSettingsSaved(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (status < 200 or status >= 300) {
        log.warn("reading prefs save failed: {d}", .{status});
        return;
    }
    log.debug("reading prefs saved", .{});
}

/// The settings blob with clientReadingPrefs replaced by the live values. A settings body that is
/// missing or unparseable yields a fresh object rather than dropping the save: the prefs are the
/// thing being written, and refusing to write them because an unrelated blob is malformed would
/// lose the user's click.
fn mergedSettings(settings_str: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var root: std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, a, settings_str, .{}) catch
        std.json.Value{ .object = .empty };
    if (root != .object) root = .{ .object = .empty };

    var prefs: std.json.ObjectMap = .empty;
    inline for (keys) |key| {
        const stored = getItem(a, "st-reading-" ++ key);
        try prefs.put(a, key, .{ .string = stored orelse defaultFor(key) });
    }
    if (getItem(a, measure_px_key)) |px| try prefs.put(a, "measurepx", .{ .string = px });

    try root.object.put(a, "clientReadingPrefs", .{ .object = prefs });

    // C-COMP appearance: rides the same save (one settings-blob owner, no clobber). Only keys the
    // user actually set are written, so an untouched appearance stays absent rather than pinned.
    var appear: std.json.ObjectMap = .empty;
    inline for (appearance.vars) |v| {
        if (getItem(a, "st-appearance-" ++ v.name)) |val| try appear.put(a, v.name, .{ .string = val });
    }
    if (getItem(a, appearance.css_key)) |css| try appear.put(a, "css", .{ .string = css });
    try root.object.put(a, "clientAppearance", .{ .object = appear });

    try persona_actions.mergePersonaState(a, &root.object); // C-PERS persona
    try backgrounds.mergeState(a, &root.object); // C-BG background
    try character_prefs.mergeCharPrefs(a, &root.object); // C-CHAR character list
    try config_state.mergeConfig(a, &root.object); // C-CFG samplers + templates
    try wi_actions.mergeWorldInfo(a, &root.object); // w3-wi globalSelect + budget
    try tag_store.global.mergeTags(a, &root.object); // w3-reason 3d tags

    return std.json.Stringify.valueAlloc(alloc, root, .{});
}
