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
const generate = @import("./generate.zig");
const conn_mod = @import("./connection.zig");
const char_store = @import("./character_store.zig");
const reading_prefs = @import("./reading_prefs.zig");

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

    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "st-sampler-{s}", .{spec.id}) catch return;
    const text = samplers.format(alloc, spec, v) catch return;
    defer alloc.free(text);
    setItem(key, text);

    applyToLiveConnection();
    reading_prefs.scheduleSave();
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
    try templates.mergeTemplates(a, root_obj, live_templates);
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
