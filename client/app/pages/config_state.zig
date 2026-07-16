//! The live state behind the two config panels: the samplers (AI Response Configuration) and the
//! instruct/context templates (AI Response Formatting).
//!
//! Both ride the SAME settings blob the classic client uses, under the keys it already reads, so a
//! value set here is a value set there. Two channels, as reading_prefs.zig established: localStorage
//! is the fast path that survives a reload before any round trip, and the account settings blob is
//! the durable target, written through reading_prefs' ONE debounced saver via `mergeConfig`. A second
//! read-modify-write saver would clobber the blob, so this module owns no settings fetch at all.
//!
//! TEMPLATE LIFETIME (probe tear 7): the templates are fifteen borrowed strings, not two, so they
//! cannot ride the Connection's dupe pattern. `live_arena` owns the parsed set; a re-mine parses into
//! a NEW arena and only then frees the old one, so a reader mid-call never sees a half-freed set. A
//! send stashes its own COPY into a second arena (char_api.stashTemplates), because the settings can
//! re-mine during the prompt-window fetch and would otherwise free the templates under the in-flight
//! build.
//!
//! zx-importing, so it is browser-verified through the interaction gate (ZX5); the model it holds
//! (templates.zig, samplers.zig) is proven natively.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const templates = @import("./templates.zig");
const samplers = @import("./samplers.zig");
const sampler_presets = @import("./sampler_presets.zig");
const nav = @import("./dropdown_nav.zig");
const generate = @import("./generate.zig");
const conn_mod = @import("./connection.zig");
const char_store = @import("./character_store.zig");
const reading_prefs = @import("./reading_prefs.zig");
const net = @import("./net.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.panels);

// ---- samplers ---------------------------------------------------------------------------------

var sampler_values: samplers.Values = samplers.defaults();
var samplers_hydrated = false;

/// The live sampler values. Hydrates once from localStorage, then from whatever the panel set.
pub fn values() samplers.Values {
    return sampler_values;
}

pub fn valueFor(id: []const u8) f64 {
    const i = samplers.indexOf(id) orelse return 0;
    return sampler_values[i];
}

/// The value a control renders, formatted per its spec. Allocated in the render allocator.
pub fn displayValue(a: std.mem.Allocator, spec: samplers.Spec) []const u8 {
    const i = samplers.indexOf(spec.id) orelse return "";
    return samplers.format(a, spec, sampler_values[i]) catch "";
}

/// Adopt the samplers the settings blob carried, then let localStorage override.
///
/// Precedence is deliberate: the BLOB is the shared truth (the classic client may have changed it),
/// and localStorage only wins for a key this browser actually set, so an untouched sampler tracks the
/// account rather than pinning whatever this browser once defaulted to.
pub fn setFrom(settings_str: []const u8) void {
    setTemplatesFrom(settings_str);
    setSelectedPresetFrom(settings_str);
    if (conn_mod.active()) |c| sampler_values = samplers.fromConnection(c);
    hydrateSamplers();
}

fn hydrateSamplers() void {
    if (zx.platform.role != .client or samplers_hydrated) return;
    samplers_hydrated = true;
    for (samplers.specs, 0..) |spec, i| {
        const stored = storedValue(spec) orelse continue;
        sampler_values[i] = stored;
    }
    applyToLiveConnection();
}

fn storedValue(spec: samplers.Spec) ?f64 {
    var buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "st-sampler-{s}", .{spec.id}) catch return null;
    const raw = getItem(alloc, key) orelse return null;
    defer alloc.free(raw);
    return samplers.parse(spec, raw);
}

/// Set one sampler from the panel: clamp it, remember it, push it at the live connection so the very
/// next send carries it, and queue the durable save.
pub fn setSampler(id: []const u8, raw: []const u8) void {
    const i = samplers.indexOf(id) orelse return;
    const spec = samplers.specs[i];
    const v = samplers.parse(spec, raw) orelse return;
    sampler_values[i] = v;
    samplers_hydrated = true;
    if (zx.platform.role != .client) return;
    storeValue(spec, v);
    applyToLiveConnection();
    reading_prefs.scheduleSave();
}

/// Pin one sampler in this browser, formatted as its spec renders it so a re-read parses back to the
/// same value.
fn storeValue(spec: samplers.Spec, v: f64) void {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "st-sampler-{s}", .{spec.id}) catch return;
    const text = samplers.format(alloc, spec, v) catch return;
    defer alloc.free(text);
    setItem(key, text);
}

/// Restore every sampler to its backend-neutral default.
pub fn resetSamplers() void {
    sampler_values = samplers.defaults();
    samplers_hydrated = true;
    if (zx.platform.role != .client) return;
    for (samplers.specs) |spec| {
        var buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "st-sampler-{s}", .{spec.id}) catch continue;
        removeItem(key);
    }
    applyToLiveConnection();
    reading_prefs.scheduleSave();
    zx.client.rerender();
}

/// Push the samplers onto the connection the send loop reads, so a panel edit needs no reload and no
/// settings refetch. The connection owns the URLs; only the scalars change here.
fn applyToLiveConnection() void {
    conn_mod.withActive(struct {
        fn apply(c: *generate.Connection) void {
            samplers.applyToConnection(sampler_values, c);
        }
    }.apply);
}

// ---- sampler presets --------------------------------------------------------------------------

// The parsed preset list and the dropdown options both borrow from `preset_arena`; a re-mine parses
// into a NEW arena and frees the old one only on success, the same lifetime the templates use above.
// The SELECTED NAME is heap-owned instead, because it must outlive a re-mine: it comes from the blob
// before the list is fetched, and it is what a save writes back.
var preset_arena: ?std.heap.ArenaAllocator = null;
var preset_list: []const sampler_presets.Preset = &.{};
var preset_options: []const nav.Option = &.{};
var selected_preset: ?[]u8 = null;
var presets_requested = false;
var presets_load_failed = false;
// How many preset files the last mine could not use. Surfaced to the panel, not just the log.
var unreadable_presets: usize = 0;
// The name a save is in flight for. The selection commits only when the server takes the file, so a
// rejected save cannot leave the picker naming a preset that does not exist.
var pending_save_name: ?[]u8 = null;

/// The preset names for the panel's dropdown.
pub fn presetOptions() []const nav.Option {
    return preset_options;
}

/// The selected preset's name, or "" when the blob names none. The dropdown falls back to its own
/// placeholder on "" (nav.selectedLabel), so a blob naming a preset whose file is gone still renders.
pub fn selectedPreset() []const u8 {
    return selected_preset orelse "";
}

/// Fetch the preset list once, on the panel's first render.
///
/// LAZY rather than on boot, and a fetch of its own rather than a hook into the boot settings load:
/// the two preset arrays are siblings of `settings` in the /api/settings/get ENVELOPE (they are not
/// inside the settings string), and char_api hands this module only the string. Nobody needs the
/// list until this panel opens, so boot pays nothing for it, and a re-open after a save re-reads a
/// list the server has already busted its cache for.
pub fn ensurePresetsLoaded() void {
    if (zx.platform.role != .client or presets_requested) return;
    presets_requested = true;
    net.request("/api/settings/get", "{}", 0, onPresetsFetched, .{});
}

fn onPresetsFetched(_: u64, status: u16, res: ?*zx.Fetch.Response) void {
    if (res == null or status < 200 or status >= 300) {
        log.warn("preset list fetch returned {d}: the picker stays empty", .{status});
        failPresetLoad();
        return;
    }
    const body = res.?.text() catch {
        log.warn("preset list response had no readable body", .{});
        failPresetLoad();
        return;
    };
    setPresetsFrom(body);
    zx.client.rerender();
}

/// A list that never arrived says so and offers a retry, rather than leaving an empty picker with no
/// explanation.
///
/// It must NOT re-arm itself here. `presets_requested` stays true precisely because this ends in a
/// rerender, and the panel's render calls ensurePresetsLoaded: re-arming would fetch again, fail
/// again, rerender again, and hammer an already-failing server forever. The retry is the user's.
fn failPresetLoad() void {
    presets_load_failed = true;
    setPresetStatus("Presets did not load.");
    zx.client.rerender();
}

pub fn presetsLoadFailed() bool {
    return presets_load_failed;
}

pub fn unreadablePresets() usize {
    return unreadable_presets;
}

/// Re-arm and refetch once, from the panel's Retry control.
pub fn retryPresets() void {
    if (!presets_load_failed) return;
    presets_load_failed = false;
    presets_requested = false;
    setPresetStatus("Loading presets...");
    ensurePresetsLoaded();
    zx.client.rerender();
}

/// Mine the preset list from a raw /api/settings/get body. Public because it is the seam a boot-path
/// caller would use instead of the lazy fetch above, and because the parse is what needs proving.
pub fn setPresetsFrom(envelope: []const u8) void {
    var next = std.heap.ArenaAllocator.init(alloc);
    const parsed = sampler_presets.parseList(next.allocator(), envelope) catch {
        next.deinit();
        log.warn("preset list parse failed: keeping the previous list", .{});
        return;
    };
    const opts = buildPresetOptions(next.allocator(), parsed.presets) catch {
        next.deinit();
        return;
    };
    if (preset_arena) |*a| a.deinit();
    preset_arena = next;
    preset_list = parsed.presets;
    preset_options = opts;
    // Any successful mine clears the failure state, whatever route got us here.
    presets_load_failed = false;
    unreadable_presets = parsed.unreadable;
    // A file the user has on disk that never shows up in the picker has to be visible somewhere they
    // will actually look, so the COUNT goes to the panel and only the reason stays here.
    if (parsed.unreadable > 0) {
        log.warn("presets: {d} usable, {d} unreadable", .{ parsed.presets.len, parsed.unreadable });
    } else {
        log.debug("presets: {d} usable", .{parsed.presets.len});
    }
}

/// The panel's line about files it could not read, or "" when every file read cleanly. Rendered from
/// the COUNT rather than pushed into the status line, because the two are different things: the
/// status reports an EVENT (a save landed, a load failed) and this describes a standing PROPERTY of
/// the list. Pushing it into the status would have overwritten "Preset saved" the moment the save's
/// own refetch came back. Allocated in the render allocator.
pub fn unreadableNotice(a: std.mem.Allocator) []const u8 {
    if (unreadable_presets == 0) return "";
    return std.fmt.allocPrint(a, "{d} preset file{s} could not be read and {s} not listed.", .{
        unreadable_presets,
        if (unreadable_presets == 1) "" else "s",
        if (unreadable_presets == 1) "is" else "are",
    }) catch "Some preset files could not be read and are not listed.";
}

fn buildPresetOptions(a: std.mem.Allocator, list: []const sampler_presets.Preset) ![]nav.Option {
    const opts = try a.alloc(nav.Option, list.len);
    // The file name IS the identity here: /api/presets/save keys by name and the blob records a name.
    for (list, 0..) |p, i| opts[i] = .{ .value = p.name, .label = p.name };
    return opts;
}

fn setSelectedPresetFrom(settings_str: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const name = sampler_presets.selectedNameFrom(arena.allocator(), settings_str) catch return orelse return;
    rememberSelected(name);
}

/// Copy `name` into the module's own storage. The caller's slice is a parse's or the DOM's, both
/// freed before the next save reads this.
fn rememberSelected(name: []const u8) void {
    const copy = alloc.dupe(u8, name) catch return;
    if (selected_preset) |old| alloc.free(old);
    selected_preset = copy;
}

/// Pick a preset: apply its samplers, remember the choice, and persist both.
///
/// The dropdown's onchange. `name` is borrowed for the call only.
pub fn onPresetChange(name: []const u8) void {
    const preset = sampler_presets.find(preset_list, name) orelse {
        log.warn("picked a preset that is not in the list: {s}", .{name});
        return;
    };
    const before = sampler_values;
    var next = sampler_values;
    const applied = sampler_presets.applyTo(preset, &next);
    sampler_values = next;
    samplers_hydrated = true;
    rememberSelected(name);
    log.debug("preset '{s}': {d} samplers applied", .{ name, applied });

    if (zx.platform.role != .client) return;
    // Only the samplers the preset actually moved get pinned in this browser. Writing the others
    // would pin a value the user never chose here, and localStorage outranks the blob on the next
    // boot (hydrateSamplers), so it would stop tracking the account for no reason.
    for (samplers.specs, 0..) |spec, i| {
        if (next[i] != before[i]) storeValue(spec, next[i]);
    }
    applyToLiveConnection();
    reading_prefs.scheduleSave();
    zx.client.rerender();
}

/// The filename the server says it actually wrote, copied into `buf`. Borrowed from a parse that
/// dies with this call, so it is copied rather than returned by reference.
fn savedName(res: ?*zx.Fetch.Response, buf: []u8) ?[]const u8 {
    const r = res orelse return null;
    const parsed = r.json(struct { name: []const u8 = "" }) catch return null;
    defer parsed.deinit();
    const n = parsed.value.name;
    if (n.len == 0 or n.len > buf.len) return null;
    @memcpy(buf[0..n.len], n);
    return buf[0..n.len];
}

/// Save the live samplers as a preset file under `name`.
///
/// The body rides sampler_presets.buildSaveBody: the server reads name/preset/apiId and 400s without
/// them. The last-applied preset is the base, so the samplers this panel does not model survive.
pub fn savePreset(name: []const u8) void {
    if (zx.platform.role != .client) return;
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) {
        setPresetStatus("Name the preset first.");
        return;
    }
    const base = if (selected_preset) |sel| blk: {
        const p = sampler_presets.find(preset_list, sel) orelse break :blk null;
        break :blk p.obj;
    } else null;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const body = sampler_presets.buildSaveBody(arena.allocator(), trimmed, base, sampler_values) catch {
        setPresetStatus("Could not build the preset.");
        return;
    };
    // Stashed, not committed: the picker adopts this name only once the server has taken the file.
    const pending = alloc.dupe(u8, trimmed) catch return;
    if (pending_save_name) |old| alloc.free(old);
    pending_save_name = pending;
    setPresetStatus("Saving...");
    net.request("/api/presets/save", body, 0, onPresetSaved, .{});
}

fn onPresetSaved(_: u64, status: u16, res: ?*zx.Fetch.Response) void {
    const pending = pending_save_name;
    pending_save_name = null;
    defer if (pending) |p| alloc.free(p);
    if (res == null or status < 200 or status >= 300) {
        log.warn("preset save returned {d}", .{status});
        // The selection stays where it was: naming a file the server refused to write would leave
        // the picker pointing at a preset that does not exist, and the blob would record it.
        setPresetStatus("Preset not saved. Check the name and try again.");
        zx.client.rerender();
        return;
    }
    // The SERVER's name wins, not the one the user typed. It sanitizes the filename
    // (src/endpoints/presets.js:44, sanitize-filename) and hands back what it actually wrote, so
    // "../x" lands as "..x": adopting the typed name would leave the picker, and the blob, naming a
    // file that does not exist. Falls back to the typed name only if the response carries none.
    var name_buf: [256]u8 = undefined;
    rememberSelected(savedName(res, &name_buf) orelse (pending orelse return));
    setPresetStatus("Preset saved");
    // The saved file is a new entry in the server's list, so re-mine rather than guess at it.
    presets_requested = false;
    ensurePresetsLoaded();
    // The selection is part of the blob the classic client reads, so it rides the one saver too.
    reading_prefs.scheduleSave();
    zx.client.rerender();
}

var preset_status: []u8 = &.{};

/// The line under the preset row: what the last load or save did. One line for both, because to the
/// user they are the same question (is this list real, did my save land). Owned here and copied, so
/// the render never borrows a freed slice.
pub fn presetStatus() []const u8 {
    return preset_status;
}

fn setPresetStatus(text: []const u8) void {
    const copy = alloc.dupe(u8, text) catch return;
    if (preset_status.len > 0) alloc.free(preset_status);
    preset_status = copy;
}

// ---- templates --------------------------------------------------------------------------------

var live_arena: ?std.heap.ArenaAllocator = null;
var live_templates: templates.Templates = .{};

/// The templates the next send wraps with. Borrowed from `live_arena`; a caller that outlives the
/// call must dupe them (templates.dupeTemplates).
pub fn activeTemplates() templates.Templates {
    return live_templates;
}

/// Re-mine the templates from a settings blob. Parses into a NEW arena first and swaps only on
/// success, so a malformed blob leaves the previous templates standing rather than blanking the
/// prompt shape mid-session.
pub fn setTemplatesFrom(settings_str: []const u8) void {
    var next = std.heap.ArenaAllocator.init(alloc);
    const parsed = templates.parseTemplates(next.allocator(), settings_str) catch {
        next.deinit();
        log.warn("templates: parse failed, keeping the previous set", .{});
        return;
    };
    if (live_arena) |*a| a.deinit();
    live_arena = next;
    live_templates = parsed;
    log.debug("templates: instruct '{s}' enabled={} context '{s}'", .{
        live_templates.instruct.name,
        live_templates.instruct.enabled,
        live_templates.context.name,
    });
}

/// The instruct fields the formatting panel edits, in render order. `get` reads the live value so
/// the panel always reflects what send uses.
pub const InstructField = struct {
    id: []const u8,
    label: []const u8,
    hint: []const u8,
    get: *const fn (templates.Instruct) []const u8,
};

pub const instruct_fields = [_]InstructField{
    .{ .id = "input_sequence", .label = "User prefix", .hint = "Starts a user turn.", .get = struct {
        fn f(t: templates.Instruct) []const u8 {
            return t.input_sequence;
        }
    }.f },
    .{ .id = "input_suffix", .label = "User suffix", .hint = "Ends a user turn.", .get = struct {
        fn f(t: templates.Instruct) []const u8 {
            return t.input_suffix;
        }
    }.f },
    .{ .id = "output_sequence", .label = "Assistant prefix", .hint = "Starts the character's turn.", .get = struct {
        fn f(t: templates.Instruct) []const u8 {
            return t.output_sequence;
        }
    }.f },
    .{ .id = "output_suffix", .label = "Assistant suffix", .hint = "Ends the character's turn.", .get = struct {
        fn f(t: templates.Instruct) []const u8 {
            return t.output_suffix;
        }
    }.f },
    .{ .id = "system_sequence", .label = "System prefix", .hint = "Starts a narrator turn.", .get = struct {
        fn f(t: templates.Instruct) []const u8 {
            return t.system_sequence;
        }
    }.f },
    .{ .id = "system_suffix", .label = "System suffix", .hint = "Ends a narrator turn.", .get = struct {
        fn f(t: templates.Instruct) []const u8 {
            return t.system_suffix;
        }
    }.f },
    .{ .id = "stop_sequence", .label = "Stop sequence", .hint = "Tells the backend where the reply ends.", .get = struct {
        fn f(t: templates.Instruct) []const u8 {
            return t.stop_sequence;
        }
    }.f },
    .{ .id = "story_string_prefix", .label = "System block prefix", .hint = "Wraps the card block.", .get = struct {
        fn f(t: templates.Instruct) []const u8 {
            return t.story_string_prefix;
        }
    }.f },
    .{ .id = "story_string_suffix", .label = "System block suffix", .hint = "Closes the card block.", .get = struct {
        fn f(t: templates.Instruct) []const u8 {
            return t.story_string_suffix;
        }
    }.f },
};

pub const instruct_fields_slice: []const InstructField = &instruct_fields;

/// The live value of one instruct field, for the panel's input.
pub fn instructValue(id: []const u8) []const u8 {
    for (instruct_fields) |f| {
        if (std.mem.eql(u8, f.id, id)) return f.get(live_templates.instruct);
    }
    return "";
}

pub fn instructEnabled() bool {
    return live_templates.instruct.enabled;
}

pub fn storyString() []const u8 {
    return live_templates.context.story_string;
}

pub fn chatStart() []const u8 {
    return live_templates.context.chat_start;
}

pub fn exampleSeparator() []const u8 {
    return live_templates.context.example_separator;
}

pub fn namesBehavior() templates.NamesBehavior {
    return live_templates.instruct.names_behavior;
}

/// Replace the whole live template set with an edited copy, into a fresh arena. Every setter routes
/// through here: the strings the panel hands in are the DOM's, freed when the handler returns, so
/// they must be copied before they become the live set.
fn commitTemplates(next: templates.Templates) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    const duped = templates.dupeTemplates(arena.allocator(), next) catch {
        arena.deinit();
        log.warn("templates: could not commit the edit", .{});
        return;
    };
    if (live_arena) |*a| a.deinit();
    live_arena = arena;
    live_templates = duped;
    reading_prefs.scheduleSave();
}

/// Set one instruct field from the panel.
pub fn setInstructField(id: []const u8, value: []const u8) void {
    var next = live_templates;
    inline for (std.meta.fields(templates.Instruct)) |f| {
        if (f.type == []const u8 and !comptime std.mem.eql(u8, f.name, "name")) {
            if (std.mem.eql(u8, f.name, id)) @field(next.instruct, f.name) = value;
        }
    }
    commitTemplates(next);
}

pub fn setInstructEnabled(on: bool) void {
    var next = live_templates;
    next.instruct.enabled = on;
    commitTemplates(next);
    zx.client.rerender();
}

pub fn setNamesBehavior(value: []const u8) void {
    const parsed = std.meta.stringToEnum(templates.NamesBehavior, value) orelse return;
    var next = live_templates;
    next.instruct.names_behavior = parsed;
    commitTemplates(next);
    zx.client.rerender();
}

pub fn setStoryString(value: []const u8) void {
    var next = live_templates;
    next.context.story_string = value;
    commitTemplates(next);
}

pub fn setChatStart(value: []const u8) void {
    var next = live_templates;
    next.context.chat_start = value;
    commitTemplates(next);
}

pub fn setExampleSeparator(value: []const u8) void {
    var next = live_templates;
    next.context.example_separator = value;
    commitTemplates(next);
}

/// The names-behavior options for the panel's dropdown.
pub const names_options: []const @import("./dropdown_nav.zig").Option = &.{
    .{ .value = "none", .label = "Never" },
    .{ .value = "force", .label = "Only when ambiguous" },
    .{ .value = "always", .label = "Always" },
};

// ---- the durable save -------------------------------------------------------------------------

/// Write the samplers and both templates into the settings object reading_prefs is about to save.
/// Called from reading_prefs.mergedSettings on every save, so this rides the single saver.
///
/// The templates go back under `power_user` and the samplers under the keys extractConnection reads,
/// which is what keeps the classic client in step. Both merge IN PLACE: `power_user` also holds the
/// personas and `textgenerationwebui_settings` holds the connection, and replacing either wholesale
/// would drop another panel's data.
pub fn mergeConfig(a: std.mem.Allocator, root_obj: *std.json.ObjectMap) !void {
    try samplers.merge(a, root_obj, sampler_values);
    try mergeSelectedPreset(a, root_obj);
    try templates.mergeTemplates(a, root_obj, live_templates);
}

/// Record the picked preset under the classic client's own key, so the other client opens on the
/// same preset. AFTER samplers.merge, which is what guarantees the textgen sub-object exists.
fn mergeSelectedPreset(a: std.mem.Allocator, root_obj: *std.json.ObjectMap) !void {
    const name = selected_preset orelse return;
    var tg = switch (root_obj.get("textgenerationwebui_settings") orelse return) {
        .object => |o| o,
        else => return,
    };
    try tg.put(a, "preset", .{ .string = name });
    try root_obj.put(a, "textgenerationwebui_settings", .{ .object = tg });
}

// ---- localStorage (jsz two-step per T2: window things come off js.global) ---------------------

fn localStorage() ?js.Object {
    if (zx.platform.role != .client) return null;
    return js.global.get(js.Object, "localStorage") catch {
        log.warn("localStorage unavailable: config not persisted locally", .{});
        return null;
    };
}

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
