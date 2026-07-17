//! Chat-management data flows the chat_manager panel drives: the per-character chat list (POST
//! /api/chats/search, empty query = all files), search, switch-to-chat, rename, delete, duplicate,
//! branch, export and import. Mirrors the persona_actions pattern: this module owns the network
//! calls and the panel state; chat_manager_body.zx reads the getters and delegates its handlers
//! here. The home region's row actions funnel into the same renameChatFor/deleteChatFor flows so
//! the net layer exists once (build plan 3a: shared with 1g).
//!
//! Switching goes through char_api.loadChatByName (invariant 4: the existing chat-load path and its
//! ticket sequencing), NEVER a direct store mutate. Suffix rules and destination-name minting live
//! in chat_names.zig, which `zig build test` proves; the flows here are browser-verified through the
//! interactions gate (ZX5).
//!
//! One mutation rides the wire at a time (`busy`): every flow is a prompt-confirm-POST-refresh arc
//! whose pending context lives in module state, so overlapping arcs would interleave that context.
//! The list fetch is not gated; a stale list response is dropped by sequence instead.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const net = @import("./net.zig");
const char_store = @import("./character_store.zig");
const persona_store = @import("./persona_store.zig");
const char_api = @import("./char_api.zig");
const chat_names = @import("./chat_names.zig");
const datetime = @import("./datetime.zig");
const home = @import("./home.zig");
const ui = @import("./ui.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.chatmgr);

const PREVIEW_CAP = 120;
const MAX_MINT_ATTEMPTS = 9;

pub const MgrState = enum { idle, loading, ready, err };

/// One chat file of the loaded character. All slices owned in page_gpa, freed on the next rebuild.
pub const ChatRow = struct {
    file_name: []const u8,
    file_size: []const u8,
    message_count: u64,
    when: []const u8,
    preview: []const u8,
};

/// The /search result subset. last_mes is {number|string} exactly like /recent (home.zig learned
/// this the hard way: typing it []const u8 fails the WHOLE array parse); datetime reads either.
const SearchJson = struct {
    file_name: []const u8 = "",
    file_size: []const u8 = "",
    message_count: u64 = 0,
    last_mes: std.json.Value = .null,
    preview_message: []const u8 = "",
};

/// The panel's own render handle (backgrounds.zig idiom): chat_manager_body.zx is the only consumer
/// and this module the only bumper, so list/status updates re-render the panel, not the whole shell.
pub var region: ?*zx.State(u32) = null;

fn bump() void {
    if (region) |h| h.set(h.get() +% 1);
}

var state: MgrState = .idle;
var rows: []ChatRow = &.{};
var loaded_avatar: []u8 = &.{};
var query: []u8 = &.{};
var list_seq: u32 = 0;
var status_line: []u8 = &.{};

const Op = enum { none, rename, delete, duplicate, branch };
var busy: bool = false;
var pend_op: Op = .none;
var pend_avatar: []u8 = &.{};
var pend_stem: []u8 = &.{};
var pend_new: []u8 = &.{};
var pend_point: usize = 0;
var pend_attempt: usize = 0;

// ---- getters the panel renders from --------------------------------------------------------

pub fn mgrState() MgrState {
    return state;
}

pub fn rowsSlice() []const ChatRow {
    return rows;
}

pub fn queryText() []const u8 {
    return query;
}

pub fn statusText() []const u8 {
    return status_line;
}

pub fn isBusy() bool {
    return busy;
}

/// The stem of the chat the reader has open, for the panel's "open" badge: the manager override
/// when one stands, else the selected card's default. Empty when another character is selected.
pub fn currentStem() []const u8 {
    const c = char_store.selected() orelse return "";
    if (!std.mem.eql(u8, c.avatar, loaded_avatar)) return "";
    const override = char_api.activeChatFile();
    if (override.len > 0) return override;
    return c.chat;
}

// ---- list load ------------------------------------------------------------------------------

/// Called from the panel's render: (re)load the list when the character changed or nothing loaded
/// yet. Idempotent per render; a character switch drops the stale query with the stale rows.
pub fn ensureFor(avatar: []const u8) void {
    if (zx.platform.role != .client) return;
    if (avatar.len == 0) return;
    if (!std.mem.eql(u8, loaded_avatar, avatar)) {
        setOwned(&loaded_avatar, avatar);
        setOwned(&query, "");
        setOwned(&status_line, "");
        refresh();
        return;
    }
    if (state == .idle) refresh();
}

/// Fetch the loaded character's chat list, filtered by the standing query. Sequence-guarded: only
/// the newest request may land its rows.
pub fn refresh() void {
    if (zx.platform.role != .client) return;
    if (loaded_avatar.len == 0) return;
    state = .loading;
    bump();
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = loaded_avatar,
        .query = query,
    }, .{}) catch {
        setError("chat list failed: out of memory");
        return;
    };
    defer alloc.free(body);
    list_seq +%= 1;
    net.request("/api/chats/search", body, list_seq, onListDone, .{});
}

/// Search-box submit: adopt the query and refetch. The server matches every fragment against
/// message text and the file name, so search semantics live in one place (chats.js:1457).
pub fn setQuery(q: []const u8) void {
    if (zx.platform.role != .client) return;
    setOwned(&query, q);
    refresh();
}

fn onListDone(tag: u64, http_status: u16, res: ?*zx.Fetch.Response) void {
    if (tag != list_seq) return;
    if (res == null or http_status == 0) {
        setError("chat list failed: network error");
        return;
    }
    if (http_status < 200 or http_status >= 300) {
        log.warn("chat list fetch returned {d}", .{http_status});
        setError("chat list failed");
        return;
    }
    const parsed = res.?.json([]SearchJson) catch |err| {
        log.warn("chat list response is not an array: {s}", .{@errorName(err)});
        setError("chat list failed: malformed response");
        return;
    };
    defer parsed.deinit();
    rebuildRows(parsed.value) catch |err| {
        log.err("chat rows rebuild failed: {s}", .{@errorName(err)});
        setError("chat list failed: out of memory");
        return;
    };
    state = .ready;
    log.info("chat manager: {d} chats for {s}", .{ rows.len, loaded_avatar });
    bump();
}

fn setError(msg: []const u8) void {
    state = .err;
    setOwned(&status_line, msg);
    bump();
}

fn rebuildRows(list: []const SearchJson) !void {
    freeRows();
    const now = nowMs();
    var out: std.ArrayList(ChatRow) = .empty;
    errdefer {
        for (out.items) |r| freeRow(r);
        out.deinit(alloc);
    }
    for (list) |sj| {
        if (sj.file_name.len == 0) continue;
        try out.append(alloc, try makeRow(sj, now));
    }
    rows = try out.toOwnedSlice(alloc);
}

fn makeRow(sj: SearchJson, now: f64) !ChatRow {
    const file_name = try alloc.dupe(u8, chat_names.stemOf(sj.file_name));
    errdefer alloc.free(file_name);
    const file_size = try alloc.dupe(u8, sj.file_size);
    errdefer alloc.free(file_size);
    const preview = try dupePreview(sj.preview_message);
    errdefer alloc.free(preview);
    var buf: [32]u8 = undefined;
    const then_ms = datetime.timestampMsFromJson(sj.last_mes) orelse std.math.nan(f64);
    const when = try alloc.dupe(u8, datetime.relativeText(&buf, then_ms, now));
    return .{
        .file_name = file_name,
        .file_size = file_size,
        .message_count = sj.message_count,
        .when = when,
        .preview = preview,
    };
}

/// Preview capped on a UTF-8 boundary (same contract as home.zig): never split a codepoint,
/// interpolated as escaped text only (WD47).
fn dupePreview(mes: []const u8) ![]u8 {
    if (mes.len <= PREVIEW_CAP) return alloc.dupe(u8, mes);
    var cut: usize = PREVIEW_CAP;
    while (cut > 0 and (mes[cut] & 0xC0) == 0x80) cut -= 1;
    const ellipsis = "\u{2026}";
    const out = try alloc.alloc(u8, cut + ellipsis.len);
    @memcpy(out[0..cut], mes[0..cut]);
    @memcpy(out[cut..], ellipsis);
    return out;
}

// ---- row actions ------------------------------------------------------------------------------

/// Switch the reader to the chat at `index`. Goes through char_api.loadChatByName (invariant 4);
/// the drawer closes so the switched chat is visible immediately.
pub fn openRow(index: usize) void {
    if (zx.platform.role != .client) return;
    if (index >= rows.len) return;
    const stem = rows[index].file_name;
    const ci = charIndexByAvatar(loaded_avatar) orelse {
        setStatus("open failed: character not loaded", .{});
        return;
    };
    if (std.mem.eql(u8, stem, currentStem())) {
        ui.close();
        return;
    }
    log.info("switch chat: {s}", .{stem});
    char_api.loadChatByName(ci, stem);
    ui.close();
}

pub fn renameRow(index: usize) void {
    if (index >= rows.len) return;
    renameChatFor(loaded_avatar, rows[index].file_name);
}

pub fn deleteRow(index: usize) void {
    if (index >= rows.len) return;
    deleteChatFor(loaded_avatar, rows[index].file_name);
}

/// Rename a chat file. Shared flow: the panel passes the loaded character, the home region passes
/// its row's avatar. On success the open chat follows the new name, and a renamed card-default
/// chat re-points the card (edit-attribute) so the card never orphans onto a name that no longer
/// exists (T1: the file itself is never copied or dropped here, the server does copy+unlink).
pub fn renameChatFor(avatar: []const u8, file_name: []const u8) void {
    if (zx.platform.role != .client) return;
    if (busy) return;
    const stem = chat_names.stemOf(file_name);
    const entered = promptString("Rename chat:", stem) orelse return;
    defer alloc.free(entered);
    const new_stem = chat_names.stemOf(entered);
    if (new_stem.len == 0 or std.mem.eql(u8, new_stem, stem)) return;
    const original = chat_names.withJsonl(alloc, stem) catch return;
    defer alloc.free(original);
    const renamed = chat_names.withJsonl(alloc, new_stem) catch return;
    defer alloc.free(renamed);
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = avatar,
        .original_file = original,
        .renamed_file = renamed,
    }, .{}) catch return;
    defer alloc.free(body);
    beginOp(.rename, avatar, stem, new_stem);
    net.request("/api/chats/rename", body, 0, onRenameDone, .{});
}

fn onRenameDone(tag: u64, http_status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    defer endOp();
    if (http_status < 200 or http_status >= 300) {
        setStatus("rename failed ({d})", .{http_status});
        return;
    }
    // The server sanitizes the destination; adopt the name it actually wrote.
    if (res) |r| {
        if (r.json(struct { sanitizedFileName: []const u8 = "" })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.sanitizedFileName.len > 0) setOwned(&pend_new, parsed.value.sanitizedFileName);
        } else |_| {}
    }
    const was_open = std.mem.eql(u8, pend_avatar, loaded_avatar) and std.mem.eql(u8, pend_stem, currentStem());
    if (cardByAvatar(pend_avatar)) |c| {
        if (std.mem.eql(u8, c.chat, pend_stem)) repointCard(pend_avatar, c.name, pend_new);
    }
    if (was_open) {
        if (charIndexByAvatar(pend_avatar)) |ci| char_api.loadChatByName(ci, pend_new);
    }
    setStatus("renamed to \"{s}\"", .{pend_new});
    refreshAfterMutation(pend_avatar);
}

/// Delete a chat file, confirm-gated. Exactly the named file: the route unlinks one path. A deleted
/// open chat falls back to the character's default (which reseeds a greeting if the default itself
/// was deleted); the card pointer is left alone by design, a fresh chat under the same name.
pub fn deleteChatFor(avatar: []const u8, file_name: []const u8) void {
    if (zx.platform.role != .client) return;
    if (busy) return;
    const stem = chat_names.stemOf(file_name);
    const msg = std.fmt.allocPrint(alloc, "Delete chat \"{s}\"? This cannot be undone.", .{stem}) catch return;
    defer alloc.free(msg);
    if (!confirmDialog(msg)) return;
    const chatfile = chat_names.withJsonl(alloc, stem) catch return;
    defer alloc.free(chatfile);
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = avatar,
        .chatfile = chatfile,
    }, .{}) catch return;
    defer alloc.free(body);
    beginOp(.delete, avatar, stem, "");
    net.request("/api/chats/delete", body, 0, onDeleteDone, .{});
}

fn onDeleteDone(tag: u64, http_status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    defer endOp();
    if (http_status < 200 or http_status >= 300) {
        setStatus("delete failed ({d})", .{http_status});
        return;
    }
    const was_open = std.mem.eql(u8, pend_avatar, loaded_avatar) and std.mem.eql(u8, pend_stem, currentStem());
    if (was_open) {
        if (charIndexByAvatar(pend_avatar)) |ci| char_api.loadCharacterChat(ci);
    }
    setStatus("deleted \"{s}\"", .{pend_stem});
    refreshAfterMutation(pend_avatar);
}

/// Duplicate the chat at `index` under a minted "<stem> copy" name. The server creates the copy
/// atomically (COPYFILE_EXCL) and answers 409 when the name exists; the retry bumps the mint.
pub fn duplicateRow(index: usize) void {
    if (zx.platform.role != .client) return;
    if (busy) return;
    if (index >= rows.len) return;
    beginOp(.duplicate, loaded_avatar, rows[index].file_name, "");
    pend_attempt = 0;
    postCopyLike("/api/chats/duplicate", onDuplicateDone) catch {
        endOp();
        setStatus("duplicate failed: out of memory", .{});
    };
}

fn onDuplicateDone(tag: u64, http_status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (http_status == 409 and pend_attempt + 1 < MAX_MINT_ATTEMPTS) {
        pend_attempt += 1;
        postCopyLike("/api/chats/duplicate", onDuplicateDone) catch {
            endOp();
            setStatus("duplicate failed: out of memory", .{});
        };
        return;
    }
    defer endOp();
    if (http_status < 200 or http_status >= 300) {
        setStatus("duplicate failed ({d})", .{http_status});
        return;
    }
    setStatus("duplicated as \"{s}\"", .{pend_new});
    refreshAfterMutation(pend_avatar);
}

/// Branch the chat at `index`: a byte-verbatim prefix copy up to a prompted 1-based message number.
/// On success the reader switches to the branch, ready to continue from that point.
pub fn branchRow(index: usize) void {
    if (zx.platform.role != .client) return;
    if (busy) return;
    if (index >= rows.len) return;
    const r = rows[index];
    if (r.message_count == 0) {
        setStatus("branch needs at least one message", .{});
        return;
    }
    var def_buf: [20]u8 = undefined;
    const def = std.fmt.bufPrint(&def_buf, "{d}", .{r.message_count}) catch return;
    var ask_buf: [96]u8 = undefined;
    const ask = std.fmt.bufPrint(&ask_buf, "Branch at message # (1-{d}):", .{r.message_count}) catch return;
    const entered = promptString(ask, def) orelse return;
    defer alloc.free(entered);
    const point = chat_names.parseBranchPoint(entered, @intCast(r.message_count)) orelse {
        setStatus("branch point must be 1-{d}", .{r.message_count});
        return;
    };
    beginOp(.branch, loaded_avatar, r.file_name, "");
    pend_point = point;
    pend_attempt = 0;
    postCopyLike("/api/chats/branch", onBranchDone) catch {
        endOp();
        setStatus("branch failed: out of memory", .{});
    };
}

fn onBranchDone(tag: u64, http_status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (http_status == 409 and pend_attempt + 1 < MAX_MINT_ATTEMPTS) {
        pend_attempt += 1;
        postCopyLike("/api/chats/branch", onBranchDone) catch {
            endOp();
            setStatus("branch failed: out of memory", .{});
        };
        return;
    }
    defer endOp();
    if (http_status < 200 or http_status >= 300) {
        setStatus("branch failed ({d})", .{http_status});
        return;
    }
    if (charIndexByAvatar(pend_avatar)) |ci| {
        char_api.loadChatByName(ci, pend_new);
        ui.close();
    }
    setStatus("branched as \"{s}\"", .{pend_new});
    refreshAfterMutation(pend_avatar);
}

/// Shared POST for duplicate/branch: mints the destination for the current attempt into pend_new,
/// then posts {avatar_url, file_name, new_file_name} (+ index for a branch).
fn postCopyLike(url: []const u8, on_done: net.OnDone) !void {
    const minted = try chat_names.mintName(
        alloc,
        pend_stem,
        if (pend_op == .branch) .branch else .copy,
        pend_point + 1,
        pend_attempt,
    );
    defer alloc.free(minted);
    setOwned(&pend_new, minted);
    const body = if (pend_op == .branch)
        try std.json.Stringify.valueAlloc(alloc, .{
            .avatar_url = pend_avatar,
            .file_name = pend_stem,
            .new_file_name = pend_new,
            .index = pend_point,
        }, .{})
    else
        try std.json.Stringify.valueAlloc(alloc, .{
            .avatar_url = pend_avatar,
            .file_name = pend_stem,
            .new_file_name = pend_new,
        }, .{});
    defer alloc.free(body);
    net.request(url, body, 0, on_done, .{});
}

/// Download the chat at `index` as jsonl. The blob download is browser-forced, so it hops through
/// the JS adapter (__st_chat_export), same mechanism as the character PNG export.
pub fn exportRow(index: usize) void {
    if (zx.platform.role != .client) return;
    if (index >= rows.len) return;
    const stem = rows[index].file_name;
    const ret = js.global.call(?js.Value, "__st_chat_export", .{ js.string(loaded_avatar), js.string(stem) }) catch {
        log.warn("chat export helper missing", .{});
        setStatus("export failed: helper missing", .{});
        return;
    };
    if (ret) |r| r.deinit();
    setStatus("exporting \"{s}\"", .{stem});
}

/// The import file input changed: hand off to the JS multipart adapter (__st_chat_import), which
/// posts the picked file and calls back through the bridge (importDone) so the list refreshes.
pub fn importFile() void {
    if (zx.platform.role != .client) return;
    if (loaded_avatar.len == 0) return;
    const c = cardByAvatar(loaded_avatar) orelse return;
    const user_name = if (persona_store.selected()) |p| p.name else "You";
    const ret = js.global.call(?js.Value, "__st_chat_import", .{
        js.string(loaded_avatar),
        js.string(c.name),
        js.string(user_name),
    }) catch {
        log.warn("chat import helper missing", .{});
        setStatus("import failed: helper missing", .{});
        return;
    };
    if (ret) |r| r.deinit();
    setStatus("importing\u{2026}", .{});
}

/// Called by the JS import adapter through the bridge once the upload settles either way; 0 means
/// the request never completed.
pub fn importDone(http_status: i32) void {
    if (zx.platform.role != .client) return;
    if (http_status >= 200 and http_status < 300) {
        setStatus("import complete", .{});
        refreshAfterMutation(loaded_avatar);
    } else {
        setStatus("import failed ({d})", .{http_status});
        bump();
    }
}

// ---- shared plumbing ---------------------------------------------------------------------------

/// Re-point a card whose default chat was renamed (field `chat` exists on every card, so
/// edit-attribute accepts it). Fire-and-forget beside the main arc; on success the character store
/// reloads so char_store.c.chat is current.
fn repointCard(avatar: []const u8, ch_name: []const u8, new_stem: []const u8) void {
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = avatar,
        .ch_name = ch_name,
        .field = "chat",
        .value = new_stem,
    }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/characters/edit-attribute", body, 0, onRepointDone, .{});
}

fn onRepointDone(tag: u64, http_status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (http_status < 200 or http_status >= 300) {
        log.warn("card re-point after rename returned {d}", .{http_status});
        return;
    }
    char_api.fetchCharacters();
}

fn refreshAfterMutation(avatar: []const u8) void {
    if (std.mem.eql(u8, avatar, loaded_avatar)) refresh();
    // The home landing lists these same files; keep its rows honest after any mutation.
    home.loadRecent();
}

fn beginOp(op: Op, avatar: []const u8, stem: []const u8, new_stem: []const u8) void {
    busy = true;
    pend_op = op;
    setOwned(&pend_avatar, avatar);
    setOwned(&pend_stem, stem);
    setOwned(&pend_new, new_stem);
    pend_point = 0;
    pend_attempt = 0;
    bump();
}

fn endOp() void {
    busy = false;
    pend_op = .none;
    bump();
}

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch return;
    if (status_line.len > 0) alloc.free(status_line);
    status_line = msg;
    bump();
}

fn setOwned(dst: *[]u8, src: []const u8) void {
    if (dst.len > 0) alloc.free(dst.*);
    dst.* = alloc.dupe(u8, src) catch &.{};
}

fn charIndexByAvatar(avatar: []const u8) ?usize {
    for (char_store.slice(), 0..) |c, i| {
        if (std.mem.eql(u8, c.avatar, avatar)) return i;
    }
    return null;
}

fn cardByAvatar(avatar: []const u8) ?char_store.Character {
    for (char_store.slice()) |c| {
        if (std.mem.eql(u8, c.avatar, avatar)) return c;
    }
    return null;
}

fn freeRows() void {
    for (rows) |r| freeRow(r);
    if (rows.len > 0) alloc.free(rows);
    rows = &.{};
}

fn freeRow(r: ChatRow) void {
    alloc.free(r.file_name);
    alloc.free(r.file_size);
    alloc.free(r.when);
    alloc.free(r.preview);
}

// ---- dialogs (jsz reflection, mirroring persona_actions) ---------------------------------------

fn promptString(msg: []const u8, default_value: []const u8) ?[]u8 {
    if (zx.platform.role != .client) return null;
    const out = js.global.callAlloc(?js.String, alloc, "prompt", .{ js.string(msg), js.string(default_value) }) catch return null;
    const s = out orelse return null;
    if (s.len == 0) {
        alloc.free(s);
        return null;
    }
    return s;
}

fn confirmDialog(msg: []const u8) bool {
    if (zx.platform.role != .client) return false;
    return js.global.call(bool, "confirm", .{js.string(msg)}) catch false;
}

fn nowMs() f64 {
    if (zx.platform.role != .client) return 0;
    const perf = js.global.get(js.Object, "performance") catch return 0;
    defer perf.deinit();
    const origin = perf.get(f64, "timeOrigin") catch return 0;
    const since = perf.call(f64, "now", .{}) catch return 0;
    return origin + since;
}
