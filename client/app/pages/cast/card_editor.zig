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
const net = @import("../platform/net.zig");
const uploads = @import("../platform/uploads.zig");
const char_api = @import("./char_api.zig");
const char_data = @import("./char_data.zig");
const char_store = @import("./character_store.zig");
const dom_event = @import("../platform/dom_event.zig");
const regions = @import("../shell/regions.zig");
const notifications = @import("../notify/notifications.zig");
const form_mod = @import("./card_form.zig");
const js = zx.client.js;

const alloc = char_store.page_gpa;
const log = std.log.scoped(.card);

pub const Field = form_mod.Field;
pub const specs = form_mod.specs;
pub const role_options = form_mod.role_options;

/// The four states every async surface owes the user (WD54). `saving` is `ready` with the form
/// locked, not a fifth screen.
pub const State = enum { idle, loading, ready, saving, err };

/// What the footer says after a save attempt. Cleared as soon as the form is edited again.
pub const Notice = enum { none, saved, save_failed, name_required, load_failed, avatar_saved, avatar_failed, avatar_no_reply };

/// The footer line, and the ONE place its wording lives: the panel renders it, and an edit writes it
/// straight into the live node without a re-render (see reflectNotice), so a second copy of this
/// mapping would be a second answer to the same question. Says what happened and what to do about
/// it, never a bare word (WD55).
pub fn noticeText() []const u8 {
    return switch (notice) {
        .saved => "Saved to the card.",
        .save_failed => "The server refused the save. The card on disk is unchanged.",
        .name_required => "A card needs a name before it can be saved.",
        .load_failed => "That card would not load.",
        .avatar_saved => "New image saved to the card.",
        .avatar_failed => "The server refused the image. The card keeps the one it had.",
        .avatar_no_reply => "The image never reached the server. The card keeps the one it had.",
        .none => if (dirty()) "Unsaved changes." else "",
    };
}

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
var in_flight = false;
/// Bumped on every accepted avatar upload; rides the image URL so the browser refetches bytes that
/// changed under a filename that did not.
var avatar_version: u32 = 0;

fn setOwned(dst: *[]u8, src: []const u8) void {
    if (dst.len > 0) alloc.free(dst.*);
    dst.* = alloc.dupe(u8, src) catch &.{};
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
    // Not a typed struct: card fields arrive uncoerced, so a typed parse hands the whole card's fate
    // to its oddest field (card_form's header has the contract).
    const parsed = res.?.json(std.json.Value) catch {
        log.warn("card body unparseable", .{});
        fail(.load_failed);
        return;
    };
    defer parsed.deinit();
    const json_data = form_mod.cardJsonData(parsed.value) orelse {
        // The one field worth failing on: the server sets it, and it carries the character_book the
        // save echoes back. Loading without it would arm a save that erases the book.
        log.warn("card body carries no json_data string: refusing to edit a card the save would strip", .{});
        fail(.load_failed);
        return;
    };
    fill(form_mod.readCard(parsed.value), json_data) catch {
        log.warn("card did not fit the edit buffers", .{});
        fail(.load_failed);
        return;
    };
    state = .ready;
    notice = .none;
    regions.bumpShell();
}

fn fill(c: form_mod.Card, json_data: []const u8) !void {
    if (form_init) form.deinit();
    form = form_mod.Form.init(alloc);
    form_init = true;

    try form.load(.name, c.name);
    try form.load(.description, c.description);
    try form.load(.personality, c.personality);
    try form.load(.scenario, c.scenario);
    try form.load(.first_mes, c.first_mes);
    try form.load(.mes_example, c.mes_example);
    try form.load(.creator_notes, c.creator_notes);
    try form.load(.system_prompt, c.system_prompt);
    try form.load(.post_history_instructions, c.post_history_instructions);
    try form.load(.creator, c.creator);
    try form.load(.character_version, c.character_version);
    try form.load(.world, c.world);
    try form.load(.depth_prompt_prompt, c.depth_prompt_prompt);

    const tags = try form_mod.tagsText(alloc, c.tags);
    defer alloc.free(tags);
    try form.load(.tags, tags);

    const depth = try form_mod.valueText(alloc, c.depth);
    defer alloc.free(depth);
    try form.load(.depth_prompt_depth, depth);

    const role = try form_mod.valueText(alloc, c.role);
    defer alloc.free(role);
    try form.load(.depth_prompt_role, if (form_mod.roleKnown(role)) role else "system");

    const greetings = try form_mod.greetingsAlloc(alloc, c.greetings);
    defer {
        for (greetings) |g| alloc.free(g);
        alloc.free(greetings);
    }
    try form.loadGreetings(@ptrCast(greetings));

    setOwned(&owned_json_data, json_data);
    const chat = try form_mod.valueText(alloc, c.chat);
    defer alloc.free(chat);
    setOwned(&owned_chat, chat);
    const created = try form_mod.valueText(alloc, c.create_date);
    defer alloc.free(created);
    setOwned(&owned_create_date, created);

    pass = .{
        .avatar_url = owned_avatar,
        .json_data = owned_json_data,
        .chat = owned_chat,
        .create_date = owned_create_date,
        .fav = form_mod.valueBool(c.fav),
        .talkativeness = form_mod.valueFloat(c.talkativeness, 0.5),
    };
}

/// A control changed: store the text. No re-render, so the caret stays where the user put it. The
/// footer would otherwise be told nothing until the panel next rendered for some other reason, which
/// left "Unsaved changes." absent while changes were unsaved: reflectNotice writes the one line that
/// changed straight into its own node, which is a text write on a node the user is not typing in.
pub fn setField(f: Field, text: []const u8) void {
    if (!form_init) return;
    form.set(f, text) catch {
        log.warn("edit dropped: out of memory", .{});
        return;
    };
    notice = .none;
    reflectNotice();
}

/// Writes the footer line into the live node without a render. The panel's inputs deliberately do
/// not re-render (that would cost the caret), so this is how the notice keeps up with the truth.
///
/// Writes the TEXT NODE's value, never the element's textContent. Both writers have to address the
/// same node: ziex creates one text node for `{noticeText()}` and keeps it by vnode id (render.zig
/// createPlatformNodes -> _ct, patched later by _snv). textContent's setter REPLACES an element's
/// children, so writing it here detached the node ziex holds, and every later render then patched
/// that detached node instead of the document. The first edit froze the footer at "Unsaved changes."
/// and the save, the refusals and the image lines all landed where no user could read them.
fn reflectNotice() void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(alloc, "card-editor-notice") orelse return;
    defer el.deinit();
    // No text child means ziex holds no node for this line either, so the next render writes it.
    const text_node = el.ref.get(js.Object, "firstChild") catch return;
    defer text_node.deinit();
    text_node.set("nodeValue", js.string(noticeText())) catch {};
}

// ---- alternate greetings --------------------------------------------------------------------

pub fn greetingCount() usize {
    if (!form_init) return 0;
    return form.greetingCount();
}

pub fn greetingText(i: usize) []const u8 {
    if (!form_init) return "";
    return form.greeting(i);
}

/// The greeting control's element id, so its label can point at it natively.
pub fn greetingDomId(arena: std.mem.Allocator, i: usize) []const u8 {
    return std.fmt.allocPrint(arena, "card-greeting-{d}", .{i}) catch "card-greeting";
}

/// The greeting's `data-card-greeting` key. One-based on purpose: dom_event.datasetUp frees an
/// EMPTY dataset value, so row zero written as "0" is fine but the empty string would be
/// undispatchable, and this keeps the two ends honest about which number they mean.
pub fn greetingKey(arena: std.mem.Allocator, i: usize) []const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{i}) catch "0";
}

pub fn greetingIndex(key: []const u8) ?usize {
    return std.fmt.parseInt(usize, key, 10) catch null;
}

/// Every Remove button reads "Remove", so each needs its own accessible name or a screen reader
/// hears the same word N times with no way to tell the rows apart (WD38).
pub fn greetingRemoveLabel(arena: std.mem.Allocator, i: usize) []const u8 {
    return std.fmt.allocPrint(arena, "Remove greeting {d}", .{i}) catch "Remove greeting";
}

/// A greeting textarea changed. Same no-render path as setField, for the same caret reason.
pub fn setGreeting(i: usize, text: []const u8) void {
    if (!form_init) return;
    form.setGreeting(i, text) catch {
        log.warn("greeting edit dropped: out of memory", .{});
        return;
    };
    notice = .none;
    reflectNotice();
}

pub fn addGreeting() void {
    if (!form_init) return;
    form.addGreeting() catch {
        log.warn("greeting add dropped: out of memory", .{});
        return;
    };
    notice = .none;
    regions.bumpShell();
    syncGreetingValues();
}

pub fn removeGreeting(i: usize) void {
    if (!form_init) return;
    form.removeGreeting(i);
    notice = .none;
    regions.bumpShell();
    syncGreetingValues();
}

/// Writes every greeting's text back into its textarea after the list's SHAPE changed.
///
/// A textarea's text child is only its DEFAULT value: once the user has typed in one, the browser
/// holds a dirty value of its own and ignores whatever the VDOM patches into that child. Removing
/// row 0 shifts row 1 up into a node the user had typed in, so without this the row would keep
/// showing the deleted text while the buffer holds the survivor's. Not a caret cost: the user
/// clicked a button, they are not typing in these.
fn syncGreetingValues() void {
    if (zx.platform.role != .client) return;
    var buf: [32]u8 = undefined;
    for (0..form.greetingCount()) |i| {
        const id = std.fmt.bufPrint(&buf, "card-greeting-{d}", .{i}) catch continue;
        const el = dom_event.elementById(alloc, id) orelse continue;
        defer el.deinit();
        el.ref.set("value", js.string(form.greeting(i))) catch {};
    }
}

// ---- avatar ---------------------------------------------------------------------------------

/// The card's current image. Cache-busted by a counter rather than a timestamp: the browser has the
/// old bytes under this exact URL, and the server writes the new image to the SAME filename.
pub fn avatarUrl(arena: std.mem.Allocator) []const u8 {
    if (owned_avatar.len == 0) return "";
    const url = char_data.thumbUrl(arena, "avatar", owned_avatar) catch return "";
    return std.fmt.allocPrint(arena, "{s}&v={d}", .{ url, avatar_version }) catch url;
}

/// The image's alt text. Names the character rather than describing the picture, which is what the
/// image is FOR here (WD40).
pub fn avatarAlt(arena: std.mem.Allocator) []const u8 {
    const n = value(.name);
    if (n.len == 0) return "The card's current image";
    return std.fmt.allocPrint(arena, "{s}'s current card image", .{n}) catch "The card's current image";
}

/// Replace the card image (multipart upload, avatar file + avatar_url). uploads.zig reads the file to
/// bytes and builds the multipart in Zig; onAvatarUploaded reports the outcome in the footer.
pub fn uploadAvatar() void {
    if (zx.platform.role != .client) return;
    if (owned_avatar.len == 0) return;
    const fields = [_]uploads.Field{.{ .name = "avatar_url", .value = owned_avatar }};
    uploads.start(.{
        .input_id = "card-avatar-input",
        .url = "/api/characters/edit-avatar",
        .fields = &fields,
        .on_done = onAvatarUploaded,
    });
}

/// uploads.zig's settle callback. `sent` is false for a cancelled picker (not an error); otherwise
/// the status tells a refusal from a request that never landed (0), stated in the footer.
fn onAvatarUploaded(status: u16, sent: bool) void {
    if (!sent) return;
    if (status >= 200 and status < 300) {
        notice = .avatar_saved;
        avatar_version += 1;
        // The list draws the same image from the same URL, so it needs the refetch to redraw too.
        char_api.fetchCharacters();
    } else {
        notice = if (status == 0) .avatar_no_reply else .avatar_failed;
        log.warn("card avatar upload failed: {d}", .{status});
        notifications.pushFmt(.err, notifications.error_ttl_ms, "Avatar upload failed: {d}", .{status});
    }
    regions.bumpShell();
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
        notifications.pushFmt(.err, notifications.error_ttl_ms, "Character save failed: {d}", .{status});
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
