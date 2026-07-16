//! The live author's note for the open chat: loaded from the chat page's header, edited by the
//! formatting panel, saved back to the chat file's own metadata.
//!
//! PER CHAT, NOT PER ACCOUNT. Unlike the samplers and the templates (which live in the account
//! settings blob and ride reading_prefs' saver), the note belongs to ONE chat file's header, so it
//! loads on chat open and saves to the chat. Opening another chat replaces it wholesale; a chat with
//! no note gets the defaults.
//!
//! THE SAVE ROUTE: POST /api/chats/metadata, the chat-metadata member of the same descriptor-mutation
//! family as message/edit and friends. The client sends only the note fields and the change token; the
//! server does the read-modify-write under the file lock and rewrites the whole file, so a windowed
//! client that holds a tail suffix can never truncate the history above its window (invariant 1). The
//! whole-file /api/chats/save is exactly what this must not use.
//!
//! zx-importing, so it is browser-verified through the interaction gate (ZX5); the note model
//! (parse, placement, interval) is proven natively in authors_note.zig.

const std = @import("std");
const zx = @import("zx");

const net = @import("./net.zig");
const an = @import("./authors_note.zig");
const char_store = @import("./character_store.zig");
const dom_event = @import("./dom_event.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.panels);

/// The open chat's note. `prompt` is owned by this module and replaced wholesale on load or edit.
var note: an.Note = .{};
var prompt_owned: []u8 = &.{};

/// The chat the note belongs to, so a save targets the chat it was edited against even if the
/// selection moved. Empty when no chat is open, which is what disables the panel's controls.
var chat_avatar: []u8 = &.{};
var chat_file: []u8 = &.{};

/// The full change token from the last chat page. The mutation family gates on the FULL token (the
/// SV design probe: a tail token hashes only the head, so two concurrent in-window edits would both
/// pass it and one would be lost silently).
var change_token: []u8 = &.{};

var saving = false;
var dirty = false;

fn setOwned(dst: *[]u8, src: []const u8) void {
    if (dst.len > 0) alloc.free(dst.*);
    dst.* = alloc.dupe(u8, src) catch &.{};
}

pub fn active() an.Note {
    return note;
}

pub fn hasChat() bool {
    return chat_file.len > 0;
}

pub fn prompt() []const u8 {
    return note.prompt;
}

pub fn depth() i64 {
    return note.depth;
}

pub fn interval() i64 {
    return note.interval;
}

pub fn position() an.Position {
    return note.position;
}

pub fn role() an.Role {
    return note.role;
}

/// Adopt the note from a freshly loaded chat page. Called on chat open, so the panel and the next
/// send both read the note that chat actually carries.
pub fn setFromPage(avatar: []const u8, file_name: []const u8, chat_metadata: []const u8, full_token: []const u8) void {
    setOwned(&chat_avatar, avatar);
    setOwned(&chat_file, file_name);
    setOwned(&change_token, full_token);
    dirty = false;

    note = .{};
    if (prompt_owned.len > 0) {
        alloc.free(prompt_owned);
        prompt_owned = &.{};
    }
    if (chat_metadata.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, chat_metadata, .{}) catch {
        log.warn("author's note: chat metadata is not json, treating the chat as noteless", .{});
        return;
    };
    defer parsed.deinit();
    const owned = an.parseOwned(alloc, parsed.value) catch return;
    note = owned;
    prompt_owned = @constCast(owned.prompt);
}

/// Refresh the token after another mutation moved it, so the next note save is not a stale 409.
pub fn adoptToken(full_token: []const u8) void {
    if (full_token.len == 0) return;
    setOwned(&change_token, full_token);
}

// ---- the panel's setters --------------------------------------------------------------------

pub fn setPrompt(text: []const u8) void {
    const copy = alloc.dupe(u8, text) catch return;
    if (prompt_owned.len > 0) alloc.free(prompt_owned);
    prompt_owned = copy;
    note.prompt = copy;
    markDirty();
}

pub fn setDepth(raw: []const u8) void {
    note.depth = @max(0, parseInt(raw) orelse return);
    markDirty();
}

pub fn setInterval(raw: []const u8) void {
    note.interval = parseInt(raw) orelse return;
    markDirty();
}

pub fn setPosition(value: []const u8) void {
    const v = parseInt(value) orelse return;
    note.position = an.Position.fromInt(v) orelse return;
    markDirty();
    zx.client.rerender();
}

pub fn setRole(value: []const u8) void {
    const v = parseInt(value) orelse return;
    note.role = an.Role.fromInt(v) orelse return;
    markDirty();
    zx.client.rerender();
}

fn parseInt(raw: []const u8) ?i64 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 0) return null;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

fn markDirty() void {
    dirty = true;
    setStatus("Unsaved changes");
}

pub fn isDirty() bool {
    return dirty;
}

// ---- the save ---------------------------------------------------------------------------------

/// Persist the note into the chat file's metadata. A no-op with no chat open (nothing to key it to)
/// or a save already in flight (the response carries the next token; firing twice would 409).
pub fn save() void {
    if (zx.platform.role != .client) return;
    if (chat_file.len == 0) {
        setStatus("Open a chat first");
        return;
    }
    if (saving) return;
    saving = true;
    setStatus("Saving note...");

    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = chat_avatar,
        .file_name = chat_file,
        .change_token = change_token,
        .note_prompt = note.prompt,
        .note_interval = note.interval,
        .note_depth = note.depth,
        .note_position = @intFromEnum(note.position),
        .note_role = @intFromEnum(note.role),
    }, .{}) catch {
        saving = false;
        return;
    };
    defer alloc.free(body);
    net.request("/api/chats/metadata", body, 0, onSaveDone, .{});
}

fn onSaveDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    saving = false;
    if (status == 409) {
        // Another writer moved the file. Adopt the token the server returned so the next save lands
        // rather than looping on a stale one, and say so instead of silently dropping the edit.
        adoptTokenFrom(res);
        setStatus("Chat changed elsewhere. Save again to apply.");
        return;
    }
    if (status < 200 or status >= 300) {
        setStatusFmt("Note save failed: {d}", .{status});
        return;
    }
    adoptTokenFrom(res);
    dirty = false;
    setStatus("Note saved");
}

fn adoptTokenFrom(res: ?*zx.Fetch.Response) void {
    const r = res orelse return;
    const parsed = r.json(struct { change_token: []const u8 = "" }) catch return;
    defer parsed.deinit();
    adoptToken(parsed.value.change_token);
}

fn setStatus(text: []const u8) void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(alloc, "an-status") orelse return;
    defer el.deinit();
    el.ref.set("textContent", zx.client.js.string(text)) catch {};
}

fn setStatusFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    setStatus(text);
}

// The panel renders these as radio-style option sets; the values are the classic client's ints, so
// what the panel writes is what stock reads.
pub const position_options: []const @import("./dropdown_nav.zig").Option = &.{
    .{ .value = "2", .label = "Before the card" },
    .{ .value = "0", .label = "After the card" },
    .{ .value = "1", .label = "In the chat" },
};

pub const role_options: []const @import("./dropdown_nav.zig").Option = &.{
    .{ .value = "0", .label = "System" },
    .{ .value = "1", .label = "User" },
    .{ .value = "2", .label = "Character" },
};

pub fn positionValue(a: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{@intFromEnum(note.position)}) catch "1";
}

pub fn roleValue(a: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{@intFromEnum(note.role)}) catch "0";
}

pub fn depthValue(a: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{note.depth}) catch "4";
}

pub fn intervalValue(a: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{note.interval}) catch "1";
}

/// Whether the depth control applies: only an in_chat note has a depth to set, so the row is hidden
/// rather than rendered dead for the anchor positions.
pub fn depthApplies() bool {
    return note.position == .in_chat;
}
