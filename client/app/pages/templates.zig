//! Instruct and context templates: the model that turns a card plus a history into the exact prompt
//! a chat-tuned model expects, replacing the one baked `Name: mes` join generate.zig used to emit.
//!
//! Two templates, exactly as the classic client splits them (both live under `power_user` in the
//! settings blob, NOT under `textgenerationwebui_settings`):
//!
//! 1. CONTEXT (`power_user.context`) owns the SYSTEM BLOCK: a `story_string` Handlebars template
//!    that orders description/personality/scenario/persona/system/world-info/author's-note anchors,
//!    plus `chat_start` and `example_separator`.
//! 2. INSTRUCT (`power_user.instruct`) owns the TURN WRAPPING: which literal sequence prefixes and
//!    suffixes a user turn, an assistant turn, and a system turn (`<|im_start|>user` ... `<|im_end|>`
//!    for ChatML), plus the `stop_sequence` that tells the backend where to stop.
//!
//! WHY A ROLE AND NOT A NAME (probe tear 1): the wrapper has to pick input_sequence vs
//! output_sequence vs system_sequence. A display name cannot decide that. A narrator turn and the
//! character's turn can carry the same name, and a persona can be named anything, so the caller
//! passes an explicit Role.
//!
//! WHY story_string NEEDS ITS OWN RENDERER (probe tear 3): it is Handlebars (`{{#if description}}`,
//! `{{trim}}`), not the flat `{{macro}}` set macros.zig resolves. Running only the flat resolver over
//! it emits a literal `{{#if description}}` into the prompt. renderStoryString below is a
//! nesting-counted subset renderer, not a regex.
//!
//! WHY THE NESTED MACRO PASS (probe tear 4): a resolved field carries its OWN macros. A system prompt
//! of "You are {{char}}." renders into the story string and must THEN become "You are Rita.". The
//! classic client does the same (power-user.js:2237 substituteParams AFTER the compile). Only a
//! headless run catches this; it type-checks fine either way.
//!
//! zx-free, so `zig build test` proves the whole model natively (ZX5). The panel that edits these
//! and the settings round-trip live in config_state.zig.

const std = @import("std");

const macros = @import("./macros.zig");

const Allocator = std.mem.Allocator;

pub const Ctx = macros.Ctx;

/// Which sequence family a turn wraps in. The prompt builder decides this from the message's own
/// flags (is_user / is_system), never from the sender's display name.
pub const Role = enum { user, assistant, system };

/// Whether a turn's text carries a `Name: ` prefix inside the wrapper.
///
/// `none` never adds one, `always` always does, and `force` adds one only when the turn cannot be
/// identified by its sequence alone. Solo chats with a single user and a single character read
/// unambiguously from the sequences, so `force` resolves to "no names" here; it becomes meaningful
/// when group chats land (3c), where several assistants share the output sequence and the name is
/// the only thing telling them apart. The classic client makes the same call
/// (instruct-mode.js:392: force includes names only when a group is selected or an avatar is forced).
pub const NamesBehavior = enum { none, force, always };

/// Where the author's note (and any other injected anchor) sits relative to the story string.
/// The integers are the classic client's `extension_prompt_types` (script.js:489) and they are what
/// `chat_metadata.note_position` stores, so they are parsed and written as-is.
pub const Position = enum(i64) {
    in_prompt = 0,
    in_chat = 1,
    before_prompt = 2,

    pub fn fromInt(v: i64) ?Position {
        return switch (v) {
            0 => .in_prompt,
            1 => .in_chat,
            2 => .before_prompt,
            else => null,
        };
    }
};

/// The turn-wrapping half. Every string is BORROWED from the arena `parseTemplates` filled; the
/// struct never owns and never frees (probe tear 7: these are 15 borrowed strings, far past what the
/// two-string Connection dupe pattern could carry, so an arena owns them as a unit).
pub const Instruct = struct {
    enabled: bool = false,
    name: []const u8 = "",
    input_sequence: []const u8 = "",
    input_suffix: []const u8 = "",
    output_sequence: []const u8 = "",
    output_suffix: []const u8 = "",
    system_sequence: []const u8 = "",
    system_suffix: []const u8 = "",
    first_output_sequence: []const u8 = "",
    last_output_sequence: []const u8 = "",
    stop_sequence: []const u8 = "",
    story_string_prefix: []const u8 = "",
    story_string_suffix: []const u8 = "",
    wrap: bool = true,
    macro: bool = true,
    names_behavior: NamesBehavior = .force,
    system_same_as_user: bool = false,
};

/// The system-block half. Strings borrowed from the same arena as Instruct.
///
/// `story_string` defaults to the stock preset, not to empty: a caller with no templates at all
/// still assembles an ORDERED system block. An empty default would silently drop the card from the
/// prompt for any caller that forgot to parse the blob.
pub const Context = struct {
    name: []const u8 = "",
    story_string: []const u8 = default_story_string,
    chat_start: []const u8 = "",
    example_separator: []const u8 = "",
};

pub const Templates = struct {
    instruct: Instruct = .{},
    context: Context = .{},
};

/// The story string the classic client ships as its Default context preset, byte-identical to
/// `default/content/presets/context/Default.json`. Used when the settings blob carries no context
/// template at all, so a fresh install still assembles an ordered system block rather than
/// concatenating card fields in field order. It already carries both anchors, so it needs no
/// migration pass.
pub const default_story_string = "{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}{{#if personality}}{{personality}}\n{{/if}}{{#if scenario}}{{scenario}}\n{{/if}}{{#if wiAfter}}{{wiAfter}}\n{{/if}}{{#if persona}}{{persona}}\n{{/if}}{{#if anchorAfter}}{{anchorAfter}}\n{{/if}}{{trim}}";

// ---- parsing (arena-owned) --------------------------------------------------------------------

/// Mines both templates out of the settings blob into `arena`. EVERY string is duped into the arena,
/// so the result outlives the json parse and the caller frees the whole set by dropping the arena.
///
/// Absent, mistyped, or non-object fields degrade to defaults rather than erroring: the templates
/// shape the prompt, and refusing to send because one blob field is a number would be worse than
/// sending the stock format. A blob with no context template still gets `default_story_string`.
pub fn parseTemplates(arena: Allocator, settings_str: []const u8) Allocator.Error!Templates {
    var out = Templates{ .context = .{ .story_string = default_story_string } };

    // An OOM must propagate, not degrade: a template silently reverting to stock because the arena
    // was full would change the prompt shape with nothing to point at.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, settings_str, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return out,
    };
    const root = switch (parsed) {
        .object => |o| o,
        else => return out,
    };
    const power_user = switch (root.get("power_user") orelse return out) {
        .object => |o| o,
        else => return out,
    };

    if (power_user.get("instruct")) |v| {
        if (v == .object) out.instruct = try parseInstruct(arena, v.object);
    }
    if (power_user.get("context")) |v| {
        if (v == .object) out.context = try parseContext(arena, v.object);
    }
    return out;
}

fn parseInstruct(arena: Allocator, o: std.json.ObjectMap) Allocator.Error!Instruct {
    return .{
        .enabled = boolField(o, "enabled", false),
        .name = try strField(arena, o, "name"),
        .input_sequence = try strField(arena, o, "input_sequence"),
        .input_suffix = try strField(arena, o, "input_suffix"),
        .output_sequence = try strField(arena, o, "output_sequence"),
        .output_suffix = try strField(arena, o, "output_suffix"),
        .system_sequence = try strField(arena, o, "system_sequence"),
        .system_suffix = try strField(arena, o, "system_suffix"),
        .first_output_sequence = try strField(arena, o, "first_output_sequence"),
        .last_output_sequence = try strField(arena, o, "last_output_sequence"),
        .stop_sequence = try strField(arena, o, "stop_sequence"),
        .story_string_prefix = try strField(arena, o, "story_string_prefix"),
        .story_string_suffix = try strField(arena, o, "story_string_suffix"),
        .wrap = boolField(o, "wrap", true),
        .macro = boolField(o, "macro", true),
        .names_behavior = namesBehavior(o),
        .system_same_as_user = boolField(o, "system_same_as_user", false),
    };
}

fn parseContext(arena: Allocator, o: std.json.ObjectMap) Allocator.Error!Context {
    var story = try strField(arena, o, "story_string");
    if (story.len == 0) story = default_story_string;
    // The classic client's one-time migration (power-user.js:1935 autoFixStoryString), same trigger:
    // a context with no `story_string_position` predates the anchors and gets them inserted. Without
    // this an author's note set to either anchor position vanishes with nothing to point at, because
    // an old blob's story string has no slot to render it into.
    if (o.get("story_string_position") == null) story = try autoFixAnchors(arena, story);
    return .{
        .name = try strField(arena, o, "name"),
        .story_string = story,
        .chat_start = try strField(arena, o, "chat_start"),
        .example_separator = try strField(arena, o, "example_separator"),
    };
}

/// Inserts the author's-note anchor fields into a story string that lacks them: anchorBefore at the
/// head, anchorAfter at the tail (before any `{{trim}}`). Byte-for-byte the classic client's
/// autoFixMissingField. A story string that already names a field is left alone, so a user who
/// deliberately positioned an anchor keeps their layout.
fn autoFixAnchors(arena: Allocator, story: []const u8) Allocator.Error![]const u8 {
    const with_before = try insertField(arena, story, "anchorBefore", .start);
    return insertField(arena, with_before, "anchorAfter", .end);
}

fn insertField(arena: Allocator, story: []const u8, comptime field: []const u8, where: enum { start, end }) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, story, "{{" ++ field ++ "}}") != null) return story;
    const tpl = "{{#if " ++ field ++ "}}{{" ++ field ++ "}}\n{{/if}}";
    const at = switch (where) {
        .start => std.mem.indexOf(u8, story, "{{") orelse 0,
        .end => blk: {
            const last_curly = if (std.mem.lastIndexOf(u8, story, "}}")) |i| i + 2 else story.len;
            const last_trim = std.mem.lastIndexOf(u8, story, "{{trim}}") orelse story.len;
            break :blk @min(last_trim, last_curly);
        },
    };
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ story[0..at], tpl, story[at..] });
}

/// A string field duped into the arena. A non-string (the server passes settings through without
/// coercing them) reads as empty rather than poisoning the whole template.
fn strField(arena: Allocator, o: std.json.ObjectMap, key: []const u8) Allocator.Error![]const u8 {
    const v = o.get(key) orelse return "";
    return switch (v) {
        .string => |s| try arena.dupe(u8, s),
        else => "",
    };
}

/// A bool field, tolerating the string and number spellings the blob has carried historically
/// (favTruthy in char_data.zig makes the same allowance for is_user).
///
/// An UNRECOGNISED string reads as the field's DEFAULT, not as false. A bad field must cost that
/// field, and for a default-true field like `wrap` "costing itself" means staying true: falling to
/// false would silently unwrap every turn in the prompt off one junk byte in a hand-edited preset.
/// Both vocabularies are spelled out because "no" must mean false, not merely "not true".
fn boolField(o: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = o.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .string => |s| boolString(s) orelse default,
        else => default,
    };
}

fn boolString(s: []const u8) ?bool {
    const yes = [_][]const u8{ "true", "1", "yes", "on" };
    const no = [_][]const u8{ "false", "0", "no", "off" };
    for (yes) |w| {
        if (std.ascii.eqlIgnoreCase(s, w)) return true;
    }
    for (no) |w| {
        if (std.ascii.eqlIgnoreCase(s, w)) return false;
    }
    return null;
}

fn namesBehavior(o: std.json.ObjectMap) NamesBehavior {
    const v = o.get("names_behavior") orelse return .force;
    return switch (v) {
        .string => |s| std.meta.stringToEnum(NamesBehavior, s) orelse .force,
        else => .force,
    };
}

/// Every string in `t` copied into `arena`, so a template set can outlive the arena it was parsed
/// into. This is what lets a send stash the live templates and survive a settings re-mine freeing
/// them mid-flight (the same hazard stashConn covers for the connection's two URLs, except a
/// template set is fifteen strings).
///
/// Reflection, not a hand-written field list: a field added to Instruct or Context is duped the day
/// it lands. A missed field here would be a use-after-free that only shows under a race.
pub fn dupeTemplates(arena: Allocator, t: Templates) Allocator.Error!Templates {
    return .{
        .instruct = try dupeStrings(arena, Instruct, t.instruct),
        .context = try dupeStrings(arena, Context, t.context),
    };
}

fn dupeStrings(arena: Allocator, comptime T: type, v: T) Allocator.Error!T {
    var out = v;
    inline for (std.meta.fields(T)) |f| {
        if (f.type == []const u8) @field(out, f.name) = try arena.dupe(u8, @field(v, f.name));
    }
    return out;
}

/// Writes both templates back into the settings object about to be saved, IN PLACE under
/// `power_user`, preserving every other key there. `power_user` also holds the personas and the
/// persona descriptions, which another panel owns, so replacing it wholesale would delete them.
///
/// Pure, so the round-trip that actually matters (what the panel saves is what the next boot parses)
/// is proven natively rather than only in a browser. config_state.zig calls this from the one
/// debounced settings saver.
pub fn mergeTemplates(a: Allocator, root_obj: *std.json.ObjectMap, t: Templates) Allocator.Error!void {
    var power_user: std.json.ObjectMap = switch (root_obj.get("power_user") orelse std.json.Value{ .object = .empty }) {
        .object => |o| o,
        else => .empty,
    };
    try power_user.put(a, "instruct", .{ .object = try instructObject(a, t.instruct) });
    try power_user.put(a, "context", .{ .object = try contextObject(a, t.context) });
    try root_obj.put(a, "power_user", .{ .object = power_user });
}

fn instructObject(a: Allocator, t: Instruct) Allocator.Error!std.json.ObjectMap {
    var o: std.json.ObjectMap = .empty;
    inline for (std.meta.fields(Instruct)) |f| {
        if (f.type == []const u8) try o.put(a, f.name, .{ .string = try a.dupe(u8, @field(t, f.name)) });
    }
    try o.put(a, "enabled", .{ .bool = t.enabled });
    try o.put(a, "wrap", .{ .bool = t.wrap });
    try o.put(a, "macro", .{ .bool = t.macro });
    try o.put(a, "system_same_as_user", .{ .bool = t.system_same_as_user });
    try o.put(a, "names_behavior", .{ .string = @tagName(t.names_behavior) });
    return o;
}

fn contextObject(a: Allocator, c: Context) Allocator.Error!std.json.ObjectMap {
    var o: std.json.ObjectMap = .empty;
    inline for (std.meta.fields(Context)) |f| {
        if (f.type == []const u8) try o.put(a, f.name, .{ .string = try a.dupe(u8, @field(c, f.name)) });
    }
    // The marker the classic client keys its one-time anchor migration on: what we write already
    // carries the anchors, so stock must not insert a second pair on top.
    try o.put(a, "story_string_position", .{ .integer = 0 });
    return o;
}

// ---- the story string (Handlebars subset) -----------------------------------------------------

/// Renders a context template's story string against the ctx, then runs a macro pass over the
/// result, strips leading newlines, and guarantees a single trailing newline. Owned result.
///
/// The supported grammar is the one the stock presets actually use:
///   {{#if field}} ... {{/if}}   block, kept when `field` resolves non-empty, NESTING-COUNTED
///   {{field}}                   value substitution
///   {{trim}}                    eats the newlines on both sides of itself
/// Anything else is left verbatim, which is the same courtesy macros.zig extends an unknown macro:
/// a template this renderer cannot read degrades visibly in the prompt rather than silently blanking
/// the system block. An unterminated `{{#if}}` keeps its literal text for the same reason.
pub fn renderStoryString(alloc: Allocator, story: []const u8, ctx: Ctx) Allocator.Error![]u8 {
    const structured = try renderBlocks(alloc, story, ctx);
    defer alloc.free(structured);

    // Two stages, as the classic client does it: Handlebars resolves the story string's own vars
    // (power-user.js:2231), THEN substituteParams runs over the RESULT (:2237), which is what makes
    // a system prompt of "You are {{char}}." finish resolving. One pass ships the literal macro.
    const fields = try macros.substituteMacros(alloc, structured, ctx);
    defer alloc.free(fields);
    const substituted = try macros.substituteMacros(alloc, fields, ctx);
    defer alloc.free(substituted);

    const trimmed = try applyTrim(alloc, substituted);
    defer alloc.free(trimmed);

    const lead = std.mem.indexOfNone(u8, trimmed, "\n") orelse trimmed.len;
    const body = trimmed[lead..];
    if (body.len == 0) return alloc.dupe(u8, "");
    if (std.mem.endsWith(u8, body, "\n")) return alloc.dupe(u8, body);
    return std.fmt.allocPrint(alloc, "{s}\n", .{body});
}

/// One pass over the template resolving `{{#if}}` blocks and `{{field}}` values. `{{trim}}` is
/// carried through verbatim for applyTrim to handle after the macro pass, matching the classic
/// client's ordering (macros.js:580 runs the trim regex at the end).
fn renderBlocks(alloc: Allocator, story: []const u8, ctx: Ctx) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < story.len) {
        const open = std.mem.indexOfPos(u8, story, i, "{{#if ") orelse {
            try out.appendSlice(alloc, story[i..]);
            break;
        };
        try out.appendSlice(alloc, story[i..open]);

        const name_end = std.mem.indexOfPos(u8, story, open, "}}") orelse {
            try out.appendSlice(alloc, story[open..]);
            break;
        };
        const field = std.mem.trim(u8, story[open + "{{#if ".len .. name_end], " \t");
        const body_start = name_end + 2;

        const close = findClose(story, body_start) orelse {
            try out.appendSlice(alloc, story[open..]);
            break;
        };

        if (truthy(field, ctx)) {
            const inner = try renderBlocks(alloc, story[body_start..close.body_end], ctx);
            defer alloc.free(inner);
            try out.appendSlice(alloc, inner);
        }
        i = close.after;
    }
    return out.toOwnedSlice(alloc);
}

const Close = struct { body_end: usize, after: usize };

/// The `{{/if}}` matching the block that starts at `from`, counting nested `{{#if}}` opens so an
/// inner block's close cannot be mistaken for the outer one's. Null when the block never closes.
fn findClose(story: []const u8, from: usize) ?Close {
    var depth: usize = 1;
    var i = from;
    while (i < story.len) {
        const next_open = std.mem.indexOfPos(u8, story, i, "{{#if ");
        const next_close = std.mem.indexOfPos(u8, story, i, "{{/if}}") orelse return null;
        if (next_open != null and next_open.? < next_close) {
            depth += 1;
            i = next_open.? + "{{#if ".len;
            continue;
        }
        depth -= 1;
        if (depth == 0) return .{ .body_end = next_close, .after = next_close + "{{/if}}".len };
        i = next_close + "{{/if}}".len;
    }
    return null;
}

/// Handlebars truthiness for the fields a story string addresses: a field is truthy when it resolves
/// to a non-empty string. An unknown field name is falsy, which drops its block, matching Handlebars
/// on an undefined variable.
fn truthy(field: []const u8, ctx: Ctx) bool {
    const val = macros.resolve(field, ctx) orelse return false;
    return val.len > 0;
}

/// Applies `{{trim}}`: the marker and every newline touching it on either side collapse to nothing.
/// Mirrors the classic client's `/(?:\r?\n)*{{trim}}(?:\r?\n)*/gi -> ''` (macros.js:580). Owned.
pub fn applyTrim(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    const marker = "{{trim}}";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        const at = std.mem.indexOfPos(u8, text, i, marker) orelse {
            try out.appendSlice(alloc, text[i..]);
            break;
        };
        try out.appendSlice(alloc, text[i..at]);
        while (out.items.len > 0 and (out.items[out.items.len - 1] == '\n' or out.items[out.items.len - 1] == '\r')) {
            _ = out.pop();
        }
        i = at + marker.len;
        while (i < text.len and (text[i] == '\n' or text[i] == '\r')) i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// ---- turn wrapping ----------------------------------------------------------------------------

/// The prefix sequence for a role, honouring `system_same_as_user` (a template that has no distinct
/// system turn folds narrator lines into the user sequence, as ChatML-less formats do).
fn prefixFor(tpl: Instruct, role: Role) []const u8 {
    return switch (role) {
        .system => if (tpl.system_same_as_user) tpl.input_sequence else tpl.system_sequence,
        .user => tpl.input_sequence,
        .assistant => tpl.output_sequence,
    };
}

fn suffixFor(tpl: Instruct, role: Role) []const u8 {
    return switch (role) {
        .system => if (tpl.system_same_as_user) tpl.input_suffix else tpl.system_suffix,
        .user => tpl.input_suffix,
        .assistant => tpl.output_suffix,
    };
}

/// Whether a turn's text carries its `Name: ` prefix. `force` is false for solo chats (the sequences
/// already identify the speaker); a system/narrator turn never carries a name, matching the classic
/// client's `isNarrator ? false` (instruct-mode.js:390).
fn includeName(tpl: Instruct, role: Role) bool {
    if (role == .system) return false;
    return tpl.names_behavior == .always;
}

/// Appends one wrapped turn straight onto `out`. With `wrap` on, an empty suffix becomes a newline
/// and the prefix is separated from the body by a newline, which is what makes an Alpaca-style
/// template (`### Instruction:` with no suffix) produce readable turns.
///
/// A template with no sequences at all (instruct disabled, or a bare blob) yields the classic
/// `Name: mes` line, so the un-templated path stays exactly what generate.zig emitted before.
///
/// This appends rather than returning an owned buffer BECAUSE the prompt builder calls it once per
/// message in the window: a per-message temp allocation would churn the wasm heap on every send, and
/// address reuse is what wakes ziex's door/VDOM pointer defects (ZX9) in unrelated components. The
/// builder appends into one buffer and allocates nothing per turn.
pub fn appendWrapped(alloc: Allocator, out: *std.ArrayList(u8), tpl: Instruct, role: Role, name: []const u8, mes: []const u8) Allocator.Error!void {
    if (!tpl.enabled) {
        try out.appendSlice(alloc, name);
        try out.appendSlice(alloc, ": ");
        try out.appendSlice(alloc, mes);
        try out.append(alloc, '\n');
        return;
    }

    const prefix = prefixFor(tpl, role);
    var suffix = suffixFor(tpl, role);
    if (suffix.len == 0 and tpl.wrap) suffix = "\n";
    const sep: []const u8 = if (tpl.wrap) "\n" else "";

    if (prefix.len > 0) {
        try out.appendSlice(alloc, prefix);
        try out.appendSlice(alloc, sep);
    }
    if (includeName(tpl, role) and name.len > 0) {
        try out.appendSlice(alloc, name);
        try out.appendSlice(alloc, ": ");
    }
    try out.appendSlice(alloc, mes);
    try out.appendSlice(alloc, suffix);
}

/// `appendWrapped` into a buffer of its own. The prompt builder does NOT use this (see above); it is
/// the shape the tests assert against and the one a one-off caller wants. Owned result.
pub fn wrapMessage(alloc: Allocator, tpl: Instruct, role: Role, name: []const u8, mes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendWrapped(alloc, &out, tpl, role, name, mes);
    return out.toOwnedSlice(alloc);
}

/// The exact byte length `wrapMessage` would produce, without building it. The budget walk calls this
/// per candidate turn, so a wrapped turn is costed at its real size.
///
/// PROBE TEAR 6: the old fixed `name + ": " + mes + "\n"` cost under-counts a ChatML turn by more
/// than 3x (`<|im_start|>user\n` + `<|im_end|>\n` is 29 bytes of overhead the old formula charged 2
/// bytes for), so the window over-filled and the backend silently truncated the OLDEST history: the
/// exact coupling invariant 2 exists to prevent. Keep this in step with wrapMessage; the test below
/// asserts they agree for every role and both templates.
pub fn wrapCost(tpl: Instruct, role: Role, name: []const u8, mes: []const u8) usize {
    if (!tpl.enabled) return name.len + 2 + mes.len + 1;

    const prefix = prefixFor(tpl, role);
    var suffix = suffixFor(tpl, role);
    if (suffix.len == 0 and tpl.wrap) suffix = "\n";
    const sep: usize = if (tpl.wrap) 1 else 0;

    var n: usize = 0;
    if (prefix.len > 0) n += prefix.len + sep;
    if (includeName(tpl, role) and name.len > 0) n += name.len + 2;
    return n + mes.len + suffix.len;
}

/// Wraps the rendered story string in the instruct template's story-string sequences, so the system
/// block arrives as a system turn the model recognises (ChatML wants `<|im_start|>system`). Owned.
pub fn wrapStoryString(alloc: Allocator, tpl: Instruct, story: []const u8) Allocator.Error![]u8 {
    if (story.len == 0) return alloc.dupe(u8, "");
    if (!tpl.enabled) return alloc.dupe(u8, story);

    const sep: []const u8 = if (tpl.wrap) "\n" else "";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (tpl.story_string_prefix.len > 0) {
        try out.appendSlice(alloc, tpl.story_string_prefix);
        try out.appendSlice(alloc, sep);
    }
    try out.appendSlice(alloc, story);
    if (tpl.story_string_suffix.len > 0) try out.appendSlice(alloc, tpl.story_string_suffix);
    return out.toOwnedSlice(alloc);
}

/// The sequence that primes the model to answer in character: the output sequence (plus a name when
/// the template asks for one), or the classic `Char:` prefix when instruct is off. Owned result.
pub fn continuationPrefix(alloc: Allocator, tpl: Instruct, char_name: []const u8) Allocator.Error![]u8 {
    if (!tpl.enabled) return std.fmt.allocPrint(alloc, "{s}:", .{char_name});

    const seq = if (tpl.last_output_sequence.len > 0) tpl.last_output_sequence else tpl.output_sequence;
    if (seq.len == 0) return std.fmt.allocPrint(alloc, "{s}:", .{char_name});
    const sep: []const u8 = if (tpl.wrap) "\n" else "";
    if (includeName(tpl, .assistant) and char_name.len > 0) {
        return std.fmt.allocPrint(alloc, "{s}{s}{s}:", .{ seq, sep, char_name });
    }
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ seq, sep });
}

const testing = std.testing;

const chatml_blob =
    \\{"power_user":{"instruct":{"enabled":true,"name":"ChatML",
    \\ "input_sequence":"<|im_start|>user","output_sequence":"<|im_start|>assistant",
    \\ "system_sequence":"<|im_start|>system","stop_sequence":"<|im_end|>",
    \\ "input_suffix":"<|im_end|>\n","output_suffix":"<|im_end|>\n","system_suffix":"<|im_end|>\n",
    \\ "story_string_prefix":"<|im_start|>system","story_string_suffix":"<|im_end|>\n",
    \\ "wrap":true,"macro":true,"names_behavior":"none","system_same_as_user":false},
    \\ "context":{"name":"ChatML","story_string":"{{#if system}}{{system}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}{{trim}}",
    \\ "chat_start":"","example_separator":""}}}
;

fn chatmlInstruct() Instruct {
    return .{
        .enabled = true,
        .input_sequence = "<|im_start|>user",
        .output_sequence = "<|im_start|>assistant",
        .system_sequence = "<|im_start|>system",
        .input_suffix = "<|im_end|>\n",
        .output_suffix = "<|im_end|>\n",
        .system_suffix = "<|im_end|>\n",
        .stop_sequence = "<|im_end|>",
        .wrap = true,
        .names_behavior = .none,
    };
}

test "parseTemplates mines both halves out of power_user" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tpl = try parseTemplates(arena.allocator(), chatml_blob);
    try testing.expect(tpl.instruct.enabled);
    try testing.expectEqualStrings("ChatML", tpl.instruct.name);
    try testing.expectEqualStrings("<|im_start|>user", tpl.instruct.input_sequence);
    try testing.expectEqualStrings("<|im_start|>assistant", tpl.instruct.output_sequence);
    try testing.expectEqualStrings("<|im_end|>\n", tpl.instruct.output_suffix);
    try testing.expectEqualStrings("<|im_end|>", tpl.instruct.stop_sequence);
    try testing.expectEqualStrings("<|im_start|>system", tpl.instruct.story_string_prefix);
    try testing.expectEqual(NamesBehavior.none, tpl.instruct.names_behavior);
    try testing.expectEqualStrings("ChatML", tpl.context.name);
    try testing.expect(std.mem.indexOf(u8, tpl.context.story_string, "{{#if system}}") != null);
}

test "parseTemplates survives the arena outliving the source blob" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tpl: Templates = undefined;
    {
        const scratch = try testing.allocator.dupe(u8, chatml_blob);
        tpl = try parseTemplates(arena.allocator(), scratch);
        // Poison then free the source: a borrowed (un-duped) field would read garbage after this.
        @memset(scratch, 'Z');
        testing.allocator.free(scratch);
    }
    try testing.expectEqualStrings("<|im_start|>user", tpl.instruct.input_sequence);
    try testing.expectEqualStrings("ChatML", tpl.instruct.name);
}

test "parseTemplates defaults a blob with no templates and keeps a story string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tpl = try parseTemplates(arena.allocator(), "{}");
    try testing.expect(!tpl.instruct.enabled);
    try testing.expectEqualStrings(default_story_string, tpl.context.story_string);
    try testing.expect(tpl.instruct.wrap);
}

test "parseTemplates tolerates hostile field shapes without losing the template" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hostile =
        \\{"power_user":{"instruct":{"enabled":1,"input_sequence":null,"output_sequence":["nope"],
        \\ "wrap":"true","names_behavior":42,"stop_sequence":"<|end|>"},
        \\ "context":{"story_string":null,"chat_start":7}}}
    ;
    const tpl = try parseTemplates(arena.allocator(), hostile);
    try testing.expect(tpl.instruct.enabled);
    try testing.expectEqualStrings("", tpl.instruct.input_sequence);
    try testing.expectEqualStrings("", tpl.instruct.output_sequence);
    try testing.expectEqualStrings("<|end|>", tpl.instruct.stop_sequence);
    try testing.expect(tpl.instruct.wrap);
    try testing.expectEqual(NamesBehavior.force, tpl.instruct.names_behavior);
    // A null story_string falls back to the default rather than emptying the system block.
    try testing.expectEqualStrings(default_story_string, tpl.context.story_string);
    try testing.expectEqualStrings("", tpl.context.chat_start);
}

test "an unreadable bool string costs its own field rather than flipping it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `wrap` defaults TRUE, so a junk string must leave it true; reading it as false would unwrap
    // every turn in the prompt and nothing on screen would say why.
    const junk =
        \\{"power_user":{"instruct":{"wrap":"banana","macro":"off","system_same_as_user":"YES"}}}
    ;
    const tpl = try parseTemplates(arena.allocator(), junk);
    try testing.expect(tpl.instruct.wrap);
    try testing.expect(!tpl.instruct.macro);
    try testing.expect(tpl.instruct.system_same_as_user);
}

test "parseTemplates degrades a malformed blob to defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tpl = try parseTemplates(arena.allocator(), "{not json");
    try testing.expect(!tpl.instruct.enabled);
    try testing.expectEqualStrings(default_story_string, tpl.context.story_string);

    const nonobj = try parseTemplates(arena.allocator(), "42");
    try testing.expectEqualStrings(default_story_string, nonobj.context.story_string);

    const wrong = try parseTemplates(arena.allocator(), "{\"power_user\":\"nope\"}");
    try testing.expectEqualStrings(default_story_string, wrong.context.story_string);
}

test "parseTemplates cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, s: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            _ = try parseTemplates(arena.allocator(), s);
        }
    }.run, .{@as([]const u8, chatml_blob)});
}

test "renderStoryString keeps a truthy field block and drops an empty one" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .personality = "" };
    const out = try renderStoryString(testing.allocator, "{{#if description}}{{description}}\n{{/if}}{{#if personality}}{{personality}}\n{{/if}}", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("A diver.\n", out);
}

test "renderStoryString runs the nested macro pass over a resolved value" {
    // The tear only a headless run catches: system resolves, and its own {{char}} must resolve too.
    const ctx = Ctx{ .char = "Rita", .system = "You are {{char}}." };
    const out = try renderStoryString(testing.allocator, "{{#if system}}{{system}}\n{{/if}}", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("You are Rita.\n", out);
}

test "renderStoryString counts nesting so an inner close does not end the outer block" {
    const ctx = Ctx{ .description = "D", .personality = "P" };
    const out = try renderStoryString(testing.allocator, "{{#if description}}A{{#if personality}}B{{/if}}C{{/if}}", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ABC\n", out);

    const inner_empty = Ctx{ .description = "D", .personality = "" };
    const out2 = try renderStoryString(testing.allocator, "{{#if description}}A{{#if personality}}B{{/if}}C{{/if}}", inner_empty);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("AC\n", out2);

    const outer_empty = Ctx{ .description = "", .personality = "P" };
    const out3 = try renderStoryString(testing.allocator, "{{#if description}}A{{#if personality}}B{{/if}}C{{/if}}tail", outer_empty);
    defer testing.allocator.free(out3);
    try testing.expectEqualStrings("tail\n", out3);
}

test "renderStoryString renders the stock Default preset in field order" {
    const ctx = Ctx{
        .char = "Rita",
        .system = "Be terse.",
        .description = "A diver.",
        .personality = "Warm.",
        .scenario = "The shoals.",
        .persona = "Jamie dives too.",
    };
    const out = try renderStoryString(testing.allocator, default_story_string, ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Be terse.\nA diver.\nWarm.\nThe shoals.\nJamie dives too.\n", out);
}

test "renderStoryString applies trim and strips leading newlines" {
    const ctx = Ctx{ .description = "D" };
    const out = try renderStoryString(testing.allocator, "\n\n{{#if description}}{{description}}\n{{/if}}{{trim}}", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("D\n", out);
}

test "renderStoryString leaves an unterminated block verbatim rather than blanking" {
    const ctx = Ctx{ .description = "D" };
    const out = try renderStoryString(testing.allocator, "head {{#if description}}never closed", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("head {{#if description}}never closed\n", out);
}

test "renderStoryString yields empty for an all-empty ctx" {
    const out = try renderStoryString(testing.allocator, default_story_string, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "renderStoryString cleans up on every allocation failure" {
    const ctx = Ctx{ .char = "Rita", .system = "You are {{char}}.", .description = "A diver." };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, c: Ctx) !void {
            const out = try renderStoryString(alloc, default_story_string, c);
            alloc.free(out);
        }
    }.run, .{ctx});
}

test "renderStoryString never panics or leaks on arbitrary template bytes" {
    var prng = std.Random.DefaultPrng.init(0x57019);
    const rand = prng.random();
    const alphabet = "{}#/if description personality \n";
    var buf: [128]u8 = undefined;
    const ctx = Ctx{ .char = "Rita", .description = "D" };
    for (0..5000) |_| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        const out = try renderStoryString(testing.allocator, buf[0..len], ctx);
        testing.allocator.free(out);
    }
}

test "applyTrim eats the newlines on both sides of the marker" {
    const out = try applyTrim(testing.allocator, "a\n\n{{trim}}\n\nb");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ab", out);

    const none = try applyTrim(testing.allocator, "no marker\n");
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("no marker\n", none);
}

test "wrapMessage wraps each role in its own ChatML sequence" {
    const tpl = chatmlInstruct();
    const user = try wrapMessage(testing.allocator, tpl, .user, "Jamie", "Hi.");
    defer testing.allocator.free(user);
    try testing.expectEqualStrings("<|im_start|>user\nHi.<|im_end|>\n", user);

    const bot = try wrapMessage(testing.allocator, tpl, .assistant, "Rita", "Hello.");
    defer testing.allocator.free(bot);
    try testing.expectEqualStrings("<|im_start|>assistant\nHello.<|im_end|>\n", bot);

    // The tear that made a narrator turn wrap as the character: system gets its OWN sequence.
    const sys = try wrapMessage(testing.allocator, tpl, .system, "Rita", "The lamp dies.");
    defer testing.allocator.free(sys);
    try testing.expectEqualStrings("<|im_start|>system\nThe lamp dies.<|im_end|>\n", sys);
}

test "wrapMessage folds a system turn into the user sequence when the template says so" {
    var tpl = chatmlInstruct();
    tpl.system_same_as_user = true;
    const sys = try wrapMessage(testing.allocator, tpl, .system, "Rita", "The lamp dies.");
    defer testing.allocator.free(sys);
    try testing.expectEqualStrings("<|im_start|>user\nThe lamp dies.<|im_end|>\n", sys);
}

test "wrapMessage emits the classic name line when instruct is off" {
    const tpl = Instruct{ .enabled = false };
    const out = try wrapMessage(testing.allocator, tpl, .user, "Jamie", "Hi.");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Jamie: Hi.\n", out);
}

test "wrapMessage adds a name only under names_behavior always" {
    var tpl = chatmlInstruct();
    tpl.names_behavior = .always;
    const named = try wrapMessage(testing.allocator, tpl, .user, "Jamie", "Hi.");
    defer testing.allocator.free(named);
    try testing.expectEqualStrings("<|im_start|>user\nJamie: Hi.<|im_end|>\n", named);

    // A narrator line never carries a name, even under always.
    const sys = try wrapMessage(testing.allocator, tpl, .system, "Rita", "Dark.");
    defer testing.allocator.free(sys);
    try testing.expectEqualStrings("<|im_start|>system\nDark.<|im_end|>\n", sys);

    tpl.names_behavior = .force;
    const forced = try wrapMessage(testing.allocator, tpl, .user, "Jamie", "Hi.");
    defer testing.allocator.free(forced);
    try testing.expectEqualStrings("<|im_start|>user\nHi.<|im_end|>\n", forced);
}

test "wrapMessage gives an Alpaca-style suffixless template a newline under wrap" {
    const tpl = Instruct{
        .enabled = true,
        .input_sequence = "### Instruction:",
        .output_sequence = "### Response:",
        .wrap = true,
        .names_behavior = .none,
    };
    const out = try wrapMessage(testing.allocator, tpl, .user, "Jamie", "Hi.");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("### Instruction:\nHi.\n", out);
}

test "wrapCost equals the real wrapped length for every role and template" {
    const templates = [_]Instruct{
        chatmlInstruct(),
        .{ .enabled = false },
        .{ .enabled = true, .input_sequence = "### Instruction:", .output_sequence = "### Response:", .wrap = true, .names_behavior = .none },
        .{ .enabled = true, .input_sequence = "U:", .output_sequence = "A:", .system_sequence = "S:", .wrap = false, .names_behavior = .always, .input_suffix = "|", .output_suffix = "|", .system_suffix = "|" },
    };
    const roles = [_]Role{ .user, .assistant, .system };
    for (templates) |tpl| {
        for (roles) |role| {
            const built = try wrapMessage(testing.allocator, tpl, role, "Jamie", "Hello there.");
            defer testing.allocator.free(built);
            try testing.expectEqual(built.len, wrapCost(tpl, role, "Jamie", "Hello there."));
        }
    }
}

test "wrapCost charges a ChatML turn its real overhead not the bare name line" {
    const tpl = chatmlInstruct();
    const cost = wrapCost(tpl, .user, "Jamie", "Hi.");
    // What the old fixed formula charged: name + ": " + mes + "\n".
    const naive = "Jamie".len + 2 + "Hi.".len + 1;
    try testing.expectEqual(@as(usize, 11), naive);
    // The wrapper's real overhead is 28 bytes (prefix 16 + separator 1 + suffix 11) against the 8
    // the naive formula assumed, so the budget walk over-fills and the backend truncates the OLDEST
    // history: exactly the display/prompt coupling invariant 2 forbids.
    try testing.expectEqual(@as(usize, 31), cost);
    try testing.expect(cost > naive * 2);
}

test "wrapStoryString wraps the system block in the story-string sequences" {
    var tpl = chatmlInstruct();
    tpl.story_string_prefix = "<|im_start|>system";
    tpl.story_string_suffix = "<|im_end|>\n";
    const out = try wrapStoryString(testing.allocator, tpl, "A diver.\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<|im_start|>system\nA diver.\n<|im_end|>\n", out);

    const empty = try wrapStoryString(testing.allocator, tpl, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);

    const off = try wrapStoryString(testing.allocator, .{ .enabled = false }, "A diver.\n");
    defer testing.allocator.free(off);
    try testing.expectEqualStrings("A diver.\n", off);
}

test "continuationPrefix primes with the output sequence or the classic char colon" {
    const tpl = chatmlInstruct();
    const out = try continuationPrefix(testing.allocator, tpl, "Rita");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<|im_start|>assistant\n", out);

    const off = try continuationPrefix(testing.allocator, .{ .enabled = false }, "Rita");
    defer testing.allocator.free(off);
    try testing.expectEqualStrings("Rita:", off);

    var named = chatmlInstruct();
    named.names_behavior = .always;
    const with_name = try continuationPrefix(testing.allocator, named, "Rita");
    defer testing.allocator.free(with_name);
    try testing.expectEqualStrings("<|im_start|>assistant\nRita:", with_name);
}

test "continuationPrefix prefers last_output_sequence when the template sets one" {
    var tpl = chatmlInstruct();
    tpl.last_output_sequence = "<|im_start|>assistant_final";
    const out = try continuationPrefix(testing.allocator, tpl, "Rita");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<|im_start|>assistant_final\n", out);
}

test "continuationPrefix falls back to the char colon when instruct has no output sequence" {
    const tpl = Instruct{ .enabled = true, .input_sequence = "U:", .output_sequence = "" };
    const out = try continuationPrefix(testing.allocator, tpl, "Rita");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita:", out);
}

test "parseTemplates migrates the anchors into a story string that predates them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const old =
        \\{"power_user":{"context":{"story_string":"{{#if description}}{{description}}\n{{/if}}"}}}
    ;
    const tpl = try parseTemplates(arena.allocator(), old);
    try testing.expectEqualStrings(
        "{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}{{#if anchorAfter}}{{anchorAfter}}\n{{/if}}",
        tpl.context.story_string,
    );

    // A note at either anchor now has a slot to render into.
    const out = try renderStoryString(testing.allocator, tpl.context.story_string, .{ .description = "D", .anchor_before = "AB", .anchor_after = "AA" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("AB\nD\nAA\n", out);
}

test "parseTemplates leaves a migrated context alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const migrated =
        \\{"power_user":{"context":{"story_string":"{{#if description}}{{description}}\n{{/if}}","story_string_position":0}}}
    ;
    const tpl = try parseTemplates(arena.allocator(), migrated);
    try testing.expectEqualStrings("{{#if description}}{{description}}\n{{/if}}", tpl.context.story_string);
}

test "parseTemplates does not duplicate an anchor the user already placed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const partial =
        \\{"power_user":{"context":{"story_string":"{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}"}}}
    ;
    const tpl = try parseTemplates(arena.allocator(), partial);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, tpl.context.story_string, "{{anchorBefore}}"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, tpl.context.story_string, "{{anchorAfter}}"));
}

test "the anchor migration puts anchorAfter before a trailing trim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const with_trim =
        \\{"power_user":{"context":{"story_string":"{{#if description}}{{description}}\n{{/if}}{{trim}}"}}}
    ;
    const tpl = try parseTemplates(arena.allocator(), with_trim);
    const anchor_at = std.mem.indexOf(u8, tpl.context.story_string, "{{anchorAfter}}").?;
    const trim_at = std.mem.indexOf(u8, tpl.context.story_string, "{{trim}}").?;
    try testing.expect(anchor_at < trim_at);
}

test "the shipped Default preset already carries both anchors and survives the migration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tpl = try parseTemplates(arena.allocator(), "{}");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, tpl.context.story_string, "{{anchorBefore}}"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, tpl.context.story_string, "{{anchorAfter}}"));
}

test "dupeTemplates copies every string field so the source arena can go" {
    var live = std.heap.ArenaAllocator.init(testing.allocator);
    var stash = std.heap.ArenaAllocator.init(testing.allocator);
    defer stash.deinit();

    var stashed: Templates = undefined;
    {
        defer live.deinit();
        const parsed = try parseTemplates(live.allocator(), chatml_blob);
        stashed = try dupeTemplates(stash.allocator(), parsed);
    }
    // The live arena is gone: a borrowed field would be freed memory here.
    try testing.expectEqualStrings("<|im_start|>user", stashed.instruct.input_sequence);
    try testing.expectEqualStrings("<|im_end|>\n", stashed.instruct.output_suffix);
    try testing.expectEqualStrings("ChatML", stashed.instruct.name);
    try testing.expectEqualStrings("ChatML", stashed.context.name);
    try testing.expect(std.mem.indexOf(u8, stashed.context.story_string, "{{#if system}}") != null);
    try testing.expect(stashed.instruct.enabled);
    try testing.expectEqual(NamesBehavior.none, stashed.instruct.names_behavior);
}

test "dupeTemplates leaves no string field aliasing the source" {
    // Reflection means a field added tomorrow is duped too; this proves none is shared today.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = Templates{
        .instruct = .{
            .enabled = true,
            .name = "n",
            .input_sequence = "a",
            .input_suffix = "b",
            .output_sequence = "c",
            .output_suffix = "d",
            .system_sequence = "e",
            .system_suffix = "f",
            .first_output_sequence = "g",
            .last_output_sequence = "h",
            .stop_sequence = "i",
            .story_string_prefix = "j",
            .story_string_suffix = "k",
        },
        .context = .{ .name = "m", .story_string = "n", .chat_start = "o", .example_separator = "p" },
    };
    const out = try dupeTemplates(arena.allocator(), src);
    inline for (std.meta.fields(Instruct)) |f| {
        if (f.type == []const u8) {
            try testing.expectEqualStrings(@field(src.instruct, f.name), @field(out.instruct, f.name));
            try testing.expect(@field(src.instruct, f.name).ptr != @field(out.instruct, f.name).ptr);
        }
    }
    inline for (std.meta.fields(Context)) |f| {
        if (f.type == []const u8) {
            try testing.expectEqualStrings(@field(src.context, f.name), @field(out.context, f.name));
            try testing.expect(@field(src.context, f.name).ptr != @field(out.context, f.name).ptr);
        }
    }
}

test "dupeTemplates cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, s: []const u8) !void {
            var live = std.heap.ArenaAllocator.init(alloc);
            defer live.deinit();
            const parsed = try parseTemplates(live.allocator(), s);
            var stash = std.heap.ArenaAllocator.init(alloc);
            defer stash.deinit();
            _ = try dupeTemplates(stash.allocator(), parsed);
        }
    }.run, .{@as([]const u8, chatml_blob)});
}

test "mergeTemplates round-trips through parseTemplates unchanged" {
    // The round-trip that matters: what the panel saves is what the next boot's send reads.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try parseTemplates(a, chatml_blob);
    var root = std.json.Value{ .object = .empty };
    try mergeTemplates(a, &root.object, src);
    const saved = try std.json.Stringify.valueAlloc(a, root, .{});
    const back = try parseTemplates(a, saved);

    inline for (std.meta.fields(Instruct)) |f| {
        if (f.type == []const u8) try testing.expectEqualStrings(@field(src.instruct, f.name), @field(back.instruct, f.name));
    }
    try testing.expectEqual(src.instruct.enabled, back.instruct.enabled);
    try testing.expectEqual(src.instruct.wrap, back.instruct.wrap);
    try testing.expectEqual(src.instruct.macro, back.instruct.macro);
    try testing.expectEqual(src.instruct.system_same_as_user, back.instruct.system_same_as_user);
    try testing.expectEqual(src.instruct.names_behavior, back.instruct.names_behavior);
    inline for (std.meta.fields(Context)) |f| {
        if (f.type == []const u8) try testing.expectEqualStrings(@field(src.context, f.name), @field(back.context, f.name));
    }
}

test "mergeTemplates keeps the personas another panel owns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"main_api":"textgenerationwebui","power_user":{"personas":{"p1.png":"Alice"},"default_persona":"p1.png"}}
    , .{});

    try mergeTemplates(a, &root.object, .{ .instruct = chatmlInstruct() });

    const pu = root.object.get("power_user").?.object;
    try testing.expectEqualStrings("Alice", pu.get("personas").?.object.get("p1.png").?.string);
    try testing.expectEqualStrings("p1.png", pu.get("default_persona").?.string);
    try testing.expectEqualStrings("<|im_start|>user", pu.get("instruct").?.object.get("input_sequence").?.string);
    try testing.expectEqualStrings("textgenerationwebui", root.object.get("main_api").?.string);
}

test "mergeTemplates writes the migration marker so stock does not double the anchors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = std.json.Value{ .object = .empty };
    try mergeTemplates(a, &root.object, .{});
    const ctx_obj = root.object.get("power_user").?.object.get("context").?.object;
    try testing.expectEqual(@as(i64, 0), ctx_obj.get("story_string_position").?.integer);

    // Re-parsing our own save must not grow a second anchor pair.
    const saved = try std.json.Stringify.valueAlloc(a, root, .{});
    const back = try parseTemplates(a, saved);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, back.context.story_string, "{{anchorBefore}}"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, back.context.story_string, "{{anchorAfter}}"));
}

test "mergeTemplates cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, s: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const t = try parseTemplates(a, s);
            var root = std.json.Value{ .object = .empty };
            try mergeTemplates(a, &root.object, t);
        }
    }.run, .{@as([]const u8, chatml_blob)});
}
