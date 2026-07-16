//! The instruct and context PRESET library: the named template files SillyTavern ships (38 instruct,
//! 34 context) plus whatever the user has saved, so picking "ChatML" replaces hand-typing
//! `<|im_start|>user` into six fields and getting one of them subtly wrong.
//!
//! WHY ITS OWN FETCH, AND NOT A HOOK ON THE SETTINGS LOAD (verified against the server, not assumed):
//! the preset arrays are NOT inside the settings blob. `/api/settings/get` answers
//! `response.send({ settings, ...payload })` (settings.js:429) where `settings` is the settings file's
//! raw TEXT and `instruct`/`context` are SIBLING keys of the payload (:307-308, :326-327). So the one
//! string every other consumer mines (config_state.setTemplatesFrom, templates.parseTemplates) cannot
//! reach them: there is nothing to hook. This module reads the RESPONSE instead. It also re-reads
//! after a save, which is what makes a just-saved preset appear in the list without a reload.
//!
//! WHY THE APPLY OWNS NO STATE OF ITS OWN: a pick rebuilds the settings blob from the live templates
//! with one half overlaid, and hands it to config_state.setTemplatesFrom, the SAME entry point the
//! boot settings load uses. A pick therefore cannot diverge from what a reload would produce, and the
//! live-template arena keeps its single owner (config_state). The cost is one stringify plus one parse
//! per pick, which is a user click, not a loop.
//!
//! TOLERANCE (these files are USER-WRITABLE and the server validates only that they are parseable
//! JSON, never their shape): an unreadable FIELD costs that field, an unreadable PRESET costs that
//! preset, and the list still renders every other one. Typed parsing is what emptied three lists on
//! this project already, so the array is walked as std.json.Value and each element is judged alone.
//!
//! WHAT IS NOT HERE: the rules. The skip ladder, the overlay and the two document compositions are
//! pure functions of their inputs, so they live in preset_lib.zig, which imports no zx and is proven
//! natively by `zig build test` (ZX5). This module is the part only a browser can verify: the fetch,
//! the arena that owns the library, the panel state and the rerenders.

const std = @import("std");
const zx = @import("zx");

const lib = @import("./preset_lib.zig");
const config_state = @import("./config_state.zig");
const reading_prefs = @import("./reading_prefs.zig");
const net = @import("./net.zig");
const char_store = @import("./character_store.zig");
const nav = @import("./dropdown_nav.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.panels);

pub const Kind = lib.Kind;
const Preset = lib.Preset;

/// The library and every string in it. Replaced wholesale by a reload, which parses into a NEW arena
/// and only then frees the old one, so a render mid-reload never reads a half-freed name.
var lib_arena: ?std.heap.ArenaAllocator = null;
var lists: [2][]const Preset = .{ &.{}, &.{} };
var options: [2][]const nav.Option = .{ &.{}, &.{} };

/// `.failed` IS THE LATCH, and it is why this stays one enum rather than gaining a parallel bool.
///
/// The panel's own render calls ensureLoaded, which fires only from `.idle`. So a failure that
/// returned to `.idle` would fetch, fail, rerender, fetch again, and hammer an already-failing server
/// forever; config_state.failPresetLoad documents that hazard because it shipped it, at 423 requests a
/// second. The sibling holds the same line with two booleans (`presets_requested` stays true beside
/// `presets_load_failed`); this module already models the load as ONE state, so a second flag would
/// let `.idle` and failed be true at once and re-arm anyway. Here re-arming is unrepresentable: only
/// retry() can reach `.idle` again, so the retry is the user's by construction rather than by care.
var load_state: enum { idle, loading, loaded, failed } = .idle;
var status_text: [2][]const u8 = .{ "", "" };
var pending_name: [2]?[]u8 = .{ null, null };

fn slot(kind: Kind) usize {
    return @intFromEnum(kind);
}

// ---- the library --------------------------------------------------------------------------------

pub fn optionsFor(kind: Kind) []const nav.Option {
    return options[slot(kind)];
}

/// The name of the live template, which is what the dropdown shows as selected. A blob whose template
/// was hand-edited carries no name and selects nothing, which is honest: the live set matches no
/// preset.
pub fn selectedFor(kind: Kind) []const u8 {
    const t = config_state.activeTemplates();
    return switch (kind) {
        .instruct => t.instruct.name,
        .context => t.context.name,
    };
}

pub fn statusFor(kind: Kind) []const u8 {
    return status_text[slot(kind)];
}

/// Whether the library fetch is still out, so an empty list can say "reading" rather than "none".
pub fn isLoading() bool {
    return load_state == .loading;
}

/// The name the save will use: what the user TYPED, and nothing until they type it.
///
/// It used to fall back to the live template's name, which put the panel's loudest control one click
/// from overwriting a shipped preset: open the panel on ChatML, click Save preset, and the server
/// takes the write with no exists-check and no confirmation (presets.js:57 writeFileAtomic), so the
/// ChatML every other chat depends on is silently replaced by whatever the fields happen to hold. An
/// empty name is refused by save() instead ("Name the preset first"), which is the sibling's rule
/// (ai_config's field is empty with a placeholder and cannot do this).
pub fn saveNameFor(kind: Kind) []const u8 {
    return pending_name[slot(kind)] orelse "";
}

pub fn setSaveName(kind: Kind, value: []const u8) void {
    const i = slot(kind);
    if (pending_name[i]) |p| alloc.free(p);
    pending_name[i] = alloc.dupe(u8, value) catch null;
}

pub fn setInstructSaveName(value: []const u8) void {
    setSaveName(.instruct, value);
}

pub fn setContextSaveName(value: []const u8) void {
    setSaveName(.context, value);
}

/// Fetch the library once. Called from the panel's render, so the presets cost nothing until the
/// user opens the panel that lists them. A load that fails latches (see `load_state`); the panel then
/// says so and the user's Retry is the only way back.
pub fn ensureLoaded() void {
    if (zx.platform.role != .client or load_state != .idle) return;
    load_state = .loading;
    net.request("/api/settings/get", "{}", 0, onLoaded, .{});
}

/// A library that never arrived says so, instead of leaving the panel painting its loading line at a
/// reader who will wait forever for a fetch that already failed.
///
/// The rerender is half the fix and the latch is the other half: without the repaint the panel keeps
/// its last frame, and without `.failed` the repaint re-arms the fetch from the render. Every failure
/// path here ends in this function for that reason, not just the bad-status one.
fn failLoad() void {
    load_state = .failed;
    zx.client.rerender();
}

/// Whether the last load failed, so the panel can offer the retry that only the user can fire.
pub fn loadFailed() bool {
    return load_state == .failed;
}

/// Re-arm and refetch once, from the panel's Retry control. The one door back to `.idle`.
pub fn retry() void {
    if (load_state != .failed) return;
    load_state = .idle;
    ensureLoaded();
    zx.client.rerender();
}

fn onLoaded(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (res == null or status < 200 or status >= 300) {
        log.warn("presets: settings fetch returned {d}, template presets unavailable", .{status});
        return failLoad();
    }
    const body = res.?.text() catch return failLoad();

    var next = std.heap.ArenaAllocator.init(alloc);
    const a = next.allocator();
    // alloc_always, NOT the default: net destroys the Response the moment this returns, so a string
    // borrowed from `body` would be freed under the list it names.
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        next.deinit();
        log.warn("presets: settings response is not JSON, keeping the previous library", .{});
        return failLoad();
    };
    const obj = switch (root) {
        .object => |o| o,
        else => {
            next.deinit();
            return failLoad();
        },
    };

    var next_lists: [2][]const Preset = .{ &.{}, &.{} };
    var next_options: [2][]const nav.Option = .{ &.{}, &.{} };
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        const kind: Kind = @enumFromInt(f.value);
        const list = lib.collect(a, obj, f.name) catch {
            next.deinit();
            log.warn("presets: out of memory building the {s} library", .{f.name});
            return failLoad();
        };
        next_lists[slot(kind)] = list;
        next_options[slot(kind)] = lib.buildOptions(a, list) catch {
            next.deinit();
            return failLoad();
        };
    }

    if (lib_arena) |*old| old.deinit();
    lib_arena = next;
    lists = next_lists;
    options = next_options;
    load_state = .loaded;
    log.debug("presets: {d} instruct, {d} context", .{ lists[0].len, lists[1].len });
    zx.client.rerender();
}

// ---- the pick -----------------------------------------------------------------------------------

pub fn pickInstruct(name: []const u8) void {
    pick(.instruct, name);
}

pub fn pickContext(name: []const u8) void {
    pick(.context, name);
}

/// Apply a preset to the live templates, so the very next send is shaped by it.
fn pick(kind: Kind, name: []const u8) void {
    const preset = lib.find(lists[slot(kind)], name) orelse return;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();

    const blob = lib.blobWith(scratch.allocator(), kind, preset.value, config_state.activeTemplates()) catch {
        log.warn("presets: could not apply '{s}', templates unchanged", .{name});
        return;
    };
    config_state.setTemplatesFrom(blob);
    reading_prefs.scheduleSave();
    status_text[slot(kind)] = "";
    zx.client.rerender();
}

// ---- the save -----------------------------------------------------------------------------------

pub fn saveInstruct() void {
    save(.instruct);
}

pub fn saveContext() void {
    save(.context);
}

/// The preset the live half came from, or null when it came from no preset we hold.
///
/// DERIVED FROM THE LIVE NAME rather than remembered from the last pick, and that is why this module
/// grows no state for it. A pick overlays the preset's own `name` into the live templates, so the live
/// name IS the record of what was picked, and it survives a reload because it rides the settings blob.
/// Remembered state would start null on every boot, so the user who picks nothing and saves (the exact
/// case that reads their blob's existing template back out) would preserve nothing.
///
/// The lookup is by name against the in-memory library, so it answers on a fresh boot: a blob naming
/// "ChatML" finds ChatML.json without the user touching the picker. A name that matches nothing is a
/// hand-edited template, and null is the honest answer for it.
fn baseFor(kind: Kind) ?std.json.ObjectMap {
    const p = lib.find(lists[slot(kind)], selectedFor(kind)) orelse return null;
    return p.value.object;
}

/// POST the live half to /api/presets/save under the typed name. The server sanitizes the name into
/// a filename and 400s without either field (presets.js:44-47), so both ride every request.
fn save(kind: Kind) void {
    if (zx.platform.role != .client) return;
    const i = slot(kind);
    const name = saveNameFor(kind);
    if (name.len == 0) {
        status_text[i] = "Name the preset first";
        zx.client.rerender();
        return;
    }

    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    // The base is borrowed from lib_arena and read only while saveBody stringifies, which is before
    // the fetch that could replace that arena is ever queued.
    const body = lib.saveBody(scratch.allocator(), kind, name, baseFor(kind), config_state.activeTemplates()) catch {
        status_text[i] = "Could not save";
        zx.client.rerender();
        return;
    };
    status_text[i] = "Saving...";
    zx.client.rerender();
    net.request("/api/presets/save", body, @intCast(i), onSaved, .{});
}

fn onSaved(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const i: usize = @intCast(tag);
    if (status >= 200 and status < 300) {
        status_text[i] = "Preset saved";
        // Re-read the library so the new name is pickable now rather than after a reload.
        load_state = .idle;
        ensureLoaded();
    } else {
        log.warn("presets: save returned {d}", .{status});
        status_text[i] = "Save failed";
    }
    zx.client.rerender();
}
