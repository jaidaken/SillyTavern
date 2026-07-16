//! The card editor's logic: the full-card fetch, its state machine, the edit buffers and the save.
//! Zig owns the data and the state; card_editor_body.zx reads it and renders. The pure half (the
//! field set, the buffers and the request body) lives in card_form.zig so `zig build test` proves it
//! (ZX5); everything here touches zx and is proven in the browser gate instead.
//!
//! WHY A SECOND FETCH: the character store holds the SHALLOW /api/characters/all form, which omits
//! the card body (char_api.zig:256 hardcodes personality/scenario/mes_example to ""). The editable
//! card is not in memory at all, so opening the panel fetches the deep card for the selected avatar
//! (/api/characters/get) into its own buffers. The store stays the list source and is untouched.

const std = @import("std");
const zx = @import("zx");
const net = @import("./net.zig");
const char_api = @import("./char_api.zig");
const char_store = @import("./character_store.zig");
const regions = @import("./regions.zig");
const form_mod = @import("./card_form.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.card);

pub const Field = form_mod.Field;
pub const specs = form_mod.specs;
pub const role_options = form_mod.role_options;

/// The four states every async surface owes the user (WD54). `saving` is `ready` with the form
/// locked, not a fifth screen.
pub const State = enum { idle, loading, ready, saving, err };

/// What the footer says after a save attempt. Cleared as soon as the form is edited again.
pub const Notice = enum { none, saved, save_failed, name_required, load_failed };

var state: State = .idle;
var notice: Notice = .none;
var form: form_mod.Form = undefined;
var form_init = false;
var pass: form_mod.Passthrough = .{ .avatar_url = "" };
/// Owned copies of the passthrough strings: the parsed response dies with its arena.
var owned_avatar: []u8 = &.{};
var owned_json_data: []u8 = &.{};
var owned_chat: []u8 = &.{};
var owned_create_date: []u8 = &.{};
var owned_greetings: [][]u8 = &.{};
var in_flight = false;

fn setOwned(dst: *[]u8, src: []const u8) void {
    if (dst.len > 0) alloc.free(dst.*);
    dst.* = alloc.dupe(u8, src) catch &.{};
}

fn freeGreetings() void {
    for (owned_greetings) |g| alloc.free(g);
    if (owned_greetings.len > 0) alloc.free(owned_greetings);
    owned_greetings = &.{};
}

pub fn editorState() State {
    return state;
}

pub fn editorNotice() Notice {
    return notice;
}

pub fn dirty() bool {
    return form_init and form.dirty();
}

/// The text a field currently holds. Empty before the card lands.
pub fn value(f: Field) []const u8 {
    if (!form_init) return "";
    return form.get(f);
}

/// The name of the character being edited, for the panel's heading.
pub fn editingName() []const u8 {
    return value(.name);
}

/// The field's `data-card-field` key, which is also how a change finds its way back to setField.
pub fn fieldKey(f: Field) []const u8 {
    return @tagName(f);
}

/// The control's element id, so its label can point at it natively. Owned by the render arena.
pub fn domId(arena: std.mem.Allocator, f: Field) []const u8 {
    return std.fmt.allocPrint(arena, "card-{s}", .{@tagName(f)}) catch "card-field";
}

/// The hint's element id, bound to the control through aria-describedby (WD40).
pub fn hintId(arena: std.mem.Allocator, f: Field) []const u8 {
    return std.fmt.allocPrint(arena, "card-{s}-hint", .{@tagName(f)}) catch "card-field-hint";
}

/// The card fields the /get response carries. The text fields are typed: every card ST writes has
/// been through charaFormatData, which forces `|| ''` on each of them. The four loose ones are
/// std.json.Value because real cards disagree on their type (fav bool vs "true", create_date string
/// vs number), and one odd field must not fail the whole editor.
const DeepDepth = struct {
    prompt: []const u8 = "",
    depth: ?std.json.Value = null,
    role: ?std.json.Value = null,
};

const DeepExt = struct {
    world: []const u8 = "",
    depth_prompt: DeepDepth = .{},
};

const DeepData = struct {
    creator_notes: []const u8 = "",
    system_prompt: []const u8 = "",
    post_history_instructions: []const u8 = "",
    creator: []const u8 = "",
    character_version: []const u8 = "",
    alternate_greetings: []const []const u8 = &.{},
    extensions: DeepExt = .{},
};

const Deep = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    personality: []const u8 = "",
    scenario: []const u8 = "",
    first_mes: []const u8 = "",
    mes_example: []const u8 = "",
    tags: []const []const u8 = &.{},
    json_data: []const u8 = "",
    chat: ?std.json.Value = null,
    create_date: ?std.json.Value = null,
    fav: ?std.json.Value = null,
    talkativeness: ?std.json.Value = null,
    data: DeepData = .{},
};

/// Called from the body on every render: loads the selected card once, and reloads when the
/// selection moved to a different character while the panel was closed.
pub fn ensureLoaded() void {
    if (zx.platform.role != .client) return;
    const c = char_store.selected() orelse return;
    if (state == .idle or !std.mem.eql(u8, owned_avatar, c.avatar)) load(c.avatar);
}

/// Discard the edit buffers and refetch the card from disk.
pub fn reload() void {
    if (zx.platform.role != .client) return;
    const c = char_store.selected() orelse return;
    state = .idle;
    load(c.avatar);
}

fn load(avatar: []const u8) void {
    if (in_flight or avatar.len == 0) return;
    const body = std.json.Stringify.valueAlloc(alloc, .{ .avatar_url = avatar }, .{}) catch {
        fail(.load_failed);
        return;
    };
    defer alloc.free(body);
    setOwned(&owned_avatar, avatar);
    in_flight = true;
    state = .loading;
    notice = .none;
    regions.bumpShell();
    net.request("/api/characters/get", body, 0, onCardDone, .{});
}

fn fail(n: Notice) void {
    state = .err;
    notice = n;
    in_flight = false;
    regions.bumpShell();
}

fn onCardDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    in_flight = false;
    if (res == null or status < 200 or status >= 300) {
        log.warn("card fetch failed: {d}", .{status});
        fail(.load_failed);
        return;
    }
    const parsed = res.?.json(Deep) catch {
        log.warn("card body unparseable", .{});
        fail(.load_failed);
        return;
    };
    defer parsed.deinit();
    fill(parsed.value) catch {
        log.warn("card did not fit the edit buffers", .{});
        fail(.load_failed);
        return;
    };
    state = .ready;
    notice = .none;
    regions.bumpShell();
}

fn fill(d: Deep) !void {
    if (form_init) form.deinit();
    form = form_mod.Form.init(alloc);
    form_init = true;

    try form.load(.name, d.name);
    try form.load(.description, d.description);
    try form.load(.personality, d.personality);
    try form.load(.scenario, d.scenario);
    try form.load(.first_mes, d.first_mes);
    try form.load(.mes_example, d.mes_example);
    try form.load(.creator_notes, d.data.creator_notes);
    try form.load(.system_prompt, d.data.system_prompt);
    try form.load(.post_history_instructions, d.data.post_history_instructions);
    try form.load(.creator, d.data.creator);
    try form.load(.character_version, d.data.character_version);
    try form.load(.world, d.data.extensions.world);
    try form.load(.depth_prompt_prompt, d.data.extensions.depth_prompt.prompt);

    const tags = try form_mod.tagsJoin(alloc, d.tags);
    defer alloc.free(tags);
    try form.load(.tags, tags);

    const depth = try form_mod.valueText(alloc, d.data.extensions.depth_prompt.depth);
    defer alloc.free(depth);
    try form.load(.depth_prompt_depth, depth);

    const role = try form_mod.valueText(alloc, d.data.extensions.depth_prompt.role);
    defer alloc.free(role);
    try form.load(.depth_prompt_role, if (role.len > 0) role else "system");

    setOwned(&owned_json_data, d.json_data);
    const chat = try form_mod.valueText(alloc, d.chat);
    defer alloc.free(chat);
    setOwned(&owned_chat, chat);
    const created = try form_mod.valueText(alloc, d.create_date);
    defer alloc.free(created);
    setOwned(&owned_create_date, created);

    freeGreetings();
    var list = try alloc.alloc([]u8, d.data.alternate_greetings.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |g| alloc.free(g);
        alloc.free(list);
    }
    for (d.data.alternate_greetings) |g| {
        list[filled] = try alloc.dupe(u8, g);
        filled += 1;
    }
    owned_greetings = list;

    pass = .{
        .avatar_url = owned_avatar,
        .json_data = owned_json_data,
        .chat = owned_chat,
        .create_date = owned_create_date,
        .fav = form_mod.valueBool(d.fav),
        .talkativeness = form_mod.valueFloat(d.talkativeness, 0.5),
        .alternate_greetings = @ptrCast(owned_greetings),
    };
}

/// A control changed: store the text. No re-render, so the caret stays where the user put it; the
/// footer's dirty state is read on the next render the panel does anyway.
pub fn setField(f: Field, text: []const u8) void {
    if (!form_init) return;
    form.set(f, text) catch {
        log.warn("edit dropped: out of memory", .{});
        return;
    };
    if (notice != .none) notice = .none;
}

/// The note role dropdown picked a value. This one DOES re-render: the dropdown is controlled, so
/// the new value has to reach its button face.
pub fn setRole(v: []const u8) void {
    setField(.depth_prompt_role, v);
    regions.bumpShell();
}

pub fn save() void {
    if (zx.platform.role != .client) return;
    if (!form_init or state == .saving or in_flight) return;
    if (!form_mod.nameValid(form.get(.name))) {
        notice = .name_required;
        regions.bumpShell();
        return;
    }
    const body = form_mod.saveBodyAlloc(alloc, &form, pass) catch {
        notice = .save_failed;
        regions.bumpShell();
        return;
    };
    defer alloc.free(body);
    in_flight = true;
    state = .saving;
    notice = .none;
    regions.bumpShell();
    net.request("/api/characters/edit", body, 0, onSaveDone, .{});
}

fn onSaveDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    in_flight = false;
    state = .ready;
    if (status < 200 or status >= 300) {
        log.warn("card save failed: {d}", .{status});
        notice = .save_failed;
        regions.bumpShell();
        return;
    }
    form.markClean() catch {};
    notice = .saved;
    log.debug("card saved: {s}", .{owned_avatar});
    // The save changed the card the list names and the send loop prompts from, and both cache it:
    // without these the list keeps the old name and the next generation uses the pre-edit fields.
    char_api.refreshDeepCard();
    char_api.fetchCharacters();
    regions.bumpShell();
}
