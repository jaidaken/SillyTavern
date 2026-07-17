//! World-info actions: the network layer over /api/worldinfo and the panel's UI state. /* w3-wi */
//!
//! world_info.zig owns the model (books, entries, scopes, budget) and is proven natively; this
//! module owns the fetches, the selection, the debounced whole-file save and the settings-blob
//! hookup, so it is browser-verified through the interaction gate (ZX5).
//!
//! The server has exactly five routes (list/get/edit/delete/import). There is no rename route:
//! rename here is the stock composite, save-under-new-name then delete-old. /edit is a WHOLE-FILE
//! save; the store serializes the parsed original so unmodeled fields ride along (T0).

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const wi = @import("./world_info.zig");
const net = @import("./net.zig");
const char_store = @import("./character_store.zig");
const reading_prefs = @import("./reading_prefs.zig");
const regions = @import("./regions.zig");
const pager = @import("./pager.zig"); // w3-wi-engine: the one full-token owner

const alloc = char_store.page_gpa;
const log = std.log.scoped(.wi);

/// The four states every async surface designs (WD54).
pub const LoadState = enum { idle, loading, ready, failed };

var list_state: LoadState = .idle;
var book_state: LoadState = .idle;

/// The open book's file_id ("" = none, list view). When open_char_book is set the read-only
/// embedded character book shows instead and open_file stays "".
var open_file: []u8 = &.{};
var open_char_book = false;

/// The selected entry's uid key within the open book ("" = none, entry list view).
var sel_entry: []u8 = &.{};

/// Save lifecycle text for the status row. Literals only, never allocated.
var save_status: []const u8 = "";

/// A fetch already in flight for openBook; a second click is dropped rather than raced.
var open_in_flight = false;
var save_in_flight = false;

pub var region: ?*zx.State(u32) = null;

fn bump() void {
    if (region) |h| h.set(h.get() +% 1);
}

fn setOwned(slot: *[]u8, value: []const u8) void {
    const copy = alloc.dupe(u8, value) catch return;
    if (slot.len > 0) alloc.free(slot.*);
    slot.* = copy;
}

fn clearOwned(slot: *[]u8) void {
    if (slot.len > 0) alloc.free(slot.*);
    slot.* = &.{};
}

// ---- render reads ------------------------------------------------------------------------------

pub fn listState() LoadState {
    return list_state;
}

pub fn bookState() LoadState {
    return book_state;
}

pub fn openFile() []const u8 {
    return open_file;
}

pub fn charBookOpen() bool {
    return open_char_book;
}

pub fn selectedEntry() []const u8 {
    return sel_entry;
}

pub fn saveStatus() []const u8 {
    return save_status;
}

/// The book the panel is editing right now: the loaded server book, or the embedded card book.
pub fn openBookPtr() ?*wi.Book {
    if (open_char_book) {
        if (wi.global.char_book) |*b| return b;
        return null;
    }
    if (open_file.len == 0) return null;
    return wi.global.bookByFileId(open_file);
}

// ---- book list (/list) --------------------------------------------------------------------------

/// First-render hook: the list loads when the drawer first opens, not at boot.
pub fn ensureListLoaded() void {
    if (zx.platform.role != .client) return;
    if (list_state != .idle) return;
    reloadList();
}

pub fn reloadList() void {
    if (zx.platform.role != .client) return;
    list_state = .loading;
    net.request("/api/worldinfo/list", "{}", 0, onListDone, .{});
}

fn onListDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (res == null or status < 200 or status >= 300) {
        list_state = .failed;
        log.warn("worldinfo list failed: {d}", .{status});
        bump();
        return;
    }
    const body = res.?.text() catch {
        list_state = .failed;
        bump();
        return;
    };
    wi.global.setBookListFromJson(body) catch |err| {
        list_state = .failed;
        log.warn("worldinfo list unparseable: {s}", .{@errorName(err)});
        bump();
        return;
    };
    list_state = .ready;
    // w3-wi-engine: names are resolvable now; load whatever the scopes reference.
    ensureScopeBooksLoaded();
    bump();
}

// ---- opening a book (/get) ----------------------------------------------------------------------

pub fn openBook(file_id: []const u8) void {
    if (zx.platform.role != .client) return;
    if (file_id.len == 0 or open_in_flight) return;
    saveNowIfDirty();
    open_char_book = false;
    clearOwned(&sel_entry);
    setOwned(&open_file, file_id);
    book_state = .loading;
    save_status = "";
    open_in_flight = true;
    const body = std.json.Stringify.valueAlloc(alloc, .{ .name = file_id }, .{}) catch {
        open_in_flight = false;
        book_state = .failed;
        return;
    };
    defer alloc.free(body);
    net.request("/api/worldinfo/get", body, 0, onBookDone, .{});
    bump();
}

fn onBookDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    open_in_flight = false;
    if (res == null or status < 200 or status >= 300) {
        book_state = .failed;
        log.warn("worldinfo get failed: {d}", .{status});
        bump();
        return;
    }
    const body = res.?.text() catch {
        book_state = .failed;
        bump();
        return;
    };
    wi.global.loadBookFromJson(open_file, body) catch |err| {
        book_state = .failed;
        log.warn("worldinfo book unparseable: {s}", .{@errorName(err)});
        bump();
        return;
    };
    book_state = .ready;
    bump();
}

/// Show the embedded character book (view only; it edits through the card).
pub fn openCharBook() void {
    if (zx.platform.role != .client) return;
    saveNowIfDirty();
    open_char_book = true;
    clearOwned(&open_file);
    clearOwned(&sel_entry);
    book_state = .ready;
    save_status = "";
    bump();
}

pub fn closeBook() void {
    if (zx.platform.role != .client) return;
    saveNowIfDirty();
    open_char_book = false;
    clearOwned(&open_file);
    clearOwned(&sel_entry);
    book_state = .idle;
    save_status = "";
    bump();
}

// ---- entry selection + edits ---------------------------------------------------------------------

pub fn selectEntry(uid_key: []const u8) void {
    setOwned(&sel_entry, uid_key);
    bump();
}

pub fn clearEntry() void {
    clearOwned(&sel_entry);
    bump();
}

fn editTarget() ?struct { book: *wi.Book, uid: []const u8 } {
    const book = openBookPtr() orelse return null;
    if (sel_entry.len == 0) return null;
    return .{ .book = book, .uid = sel_entry };
}

pub fn setStr(field: wi.StrField, value: []const u8) void {
    const t = editTarget() orelse return;
    wi.global.setEntryStr(t.book, t.uid, field, value) catch |err| {
        log.warn("entry edit failed: {s}", .{@errorName(err)});
        return;
    };
    scheduleBookSave();
}

pub fn setNum(field: wi.NumField, raw: []const u8) void {
    const t = editTarget() orelse return;
    const v = parseNum(raw) orelse return;
    wi.global.setEntryNum(t.book, t.uid, field, v) catch |err| {
        log.warn("entry edit failed: {s}", .{@errorName(err)});
        return;
    };
    scheduleBookSave();
    bump();
}

pub fn setBool(field: wi.BoolField, value: bool) void {
    const t = editTarget() orelse return;
    wi.global.setEntryBool(t.book, t.uid, field, value) catch |err| {
        log.warn("entry edit failed: {s}", .{@errorName(err)});
        return;
    };
    scheduleBookSave();
    bump();
}

pub fn setKeys(field: wi.KeyField, csv: []const u8) void {
    const t = editTarget() orelse return;
    wi.global.setEntryKeys(t.book, t.uid, field, csv) catch |err| {
        log.warn("entry edit failed: {s}", .{@errorName(err)});
        return;
    };
    scheduleBookSave();
}

fn parseNum(raw: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.fmt.parseInt(i64, trimmed, 10)) |v| return v else |_| {}
    const f = std.fmt.parseFloat(f64, trimmed) catch return null;
    if (!std.math.isFinite(f)) return null;
    return @intFromFloat(f);
}

pub fn newEntry() void {
    const book = openBookPtr() orelse return;
    const uid = wi.global.createEntry(book) catch |err| {
        log.warn("entry create failed: {s}", .{@errorName(err)});
        return;
    };
    var buf: [20]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{uid}) catch return;
    setOwned(&sel_entry, key);
    scheduleBookSave();
    bump();
}

pub fn deleteSelectedEntry() void {
    const t = editTarget() orelse return;
    if (!confirmDialog("Delete this entry? This cannot be undone.")) return;
    wi.global.deleteEntry(t.book, t.uid) catch |err| {
        log.warn("entry delete failed: {s}", .{@errorName(err)});
        return;
    };
    clearOwned(&sel_entry);
    scheduleBookSave();
    bump();
}

// ---- the debounced whole-file save (/edit) --------------------------------------------------------

const save_delay_ms = 1500;

/// ziex has setTimeout but no clearTimeout, so the debounce counts instead of cancelling
/// (the reading_prefs pattern): only the timer that finds no newer edit pending saves.
var pending_saves: u32 = 0;

fn scheduleBookSave() void {
    save_status = "Unsaved changes";
    pending_saves += 1;
    if (zx.client.setTimeout(onSaveTimeout, save_delay_ms) == null) {
        pending_saves -= 1;
        log.warn("no timer slot for the book-save debounce, saving now", .{});
        saveNowIfDirty();
    }
}

fn onSaveTimeout() void {
    if (pending_saves > 0) pending_saves -= 1;
    if (pending_saves != 0) return;
    saveNowIfDirty();
}

/// The file the in-flight /edit belongs to, so completion can find its book even if the user has
/// switched away meanwhile.
var saving_file: []u8 = &.{};

/// Flush the open book if it carries unsaved edits. Also called before switching books, so an
/// edit can never be lost to navigation. The char book is view-only and never dirty.
fn saveNowIfDirty() void {
    if (open_char_book or open_file.len == 0) return;
    const book = wi.global.bookByFileId(open_file) orelse return;
    saveBookNow(book);
}

fn saveBookNow(book: *wi.Book) void {
    if (!book.dirty or save_in_flight) return;
    const body = wi.global.serializeForEdit(book) catch |err| {
        save_status = "Save failed";
        log.err("book serialize failed: {s}", .{@errorName(err)});
        bump();
        return;
    };
    defer alloc.free(body);
    // Cleared at dispatch: an edit landing while the save is in flight re-marks it, and completion
    // flushes again, so the last write always reaches the server.
    book.dirty = false;
    setOwned(&saving_file, book.file_id);
    save_in_flight = true;
    save_status = "Saving...";
    net.request("/api/worldinfo/edit", body, 0, onSaveDone, .{});
    bump();
}

/// A book edited while another save was in flight stays dirty in the store; sweep it up.
fn flushAnyDirty() void {
    for (wi.global.books.items) |*b| {
        if (b.dirty) {
            saveBookNow(b);
            return;
        }
    }
}

fn onSaveDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    save_in_flight = false;
    if (status < 200 or status >= 300) {
        if (wi.global.bookByFileId(saving_file)) |b| b.dirty = true;
        save_status = "Save failed";
        log.warn("worldinfo edit failed: {d}", .{status});
        bump();
        return;
    }
    save_status = "Saved";
    flushAnyDirty();
    bump();
}

// ---- book CRUD (/edit create, /delete, rename composite) ----------------------------------------

/// A two-name mutation on the wire; its address rides the callback tag (the backgrounds pattern).
const Mutation = struct {
    old: []u8,
    new: []u8,
};

fn startMutation(old_name: []const u8, new_name: []const u8) ?*Mutation {
    const m = alloc.create(Mutation) catch return null;
    const old_c = alloc.dupe(u8, old_name) catch {
        alloc.destroy(m);
        return null;
    };
    const new_c = alloc.dupe(u8, new_name) catch {
        alloc.free(old_c);
        alloc.destroy(m);
        return null;
    };
    m.* = .{ .old = old_c, .new = new_c };
    return m;
}

/// Only tags minted by startMutation reach this: net.zig returns the tag untouched on every path
/// and both callbacks below are private to this module.
fn mutationFor(tag: u64) *Mutation {
    return @ptrFromInt(@as(usize, @intCast(tag)));
}

fn freeMutation(m: *Mutation) void {
    alloc.free(m.old);
    alloc.free(m.new);
    alloc.destroy(m);
}

pub fn newBook() void {
    if (zx.platform.role != .client) return;
    const name = promptString("New lorebook name:", "") orelse return;
    defer alloc.free(name);
    const m = startMutation("", name) orelse return;
    const body = std.json.Stringify.valueAlloc(alloc, .{ .name = name, .data = .{ .entries = .{} } }, .{}) catch {
        freeMutation(m);
        return;
    };
    defer alloc.free(body);
    net.request("/api/worldinfo/edit", body, @intFromPtr(m), onCreateDone, .{});
}

fn onCreateDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const m = mutationFor(tag);
    defer freeMutation(m);
    if (status < 200 or status >= 300) {
        log.warn("book create failed: {d}", .{status});
        return;
    }
    reloadList();
    openBook(m.new);
}

pub fn deleteBook(file_id: []const u8) void {
    if (zx.platform.role != .client) return;
    if (!confirmDialog("Delete this lorebook? All its entries are lost.")) return;
    const m = startMutation(file_id, "") orelse return;
    const body = std.json.Stringify.valueAlloc(alloc, .{ .name = file_id }, .{}) catch {
        freeMutation(m);
        return;
    };
    defer alloc.free(body);
    net.request("/api/worldinfo/delete", body, @intFromPtr(m), onDeleteDone, .{});
}

fn onDeleteDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const m = mutationFor(tag);
    defer freeMutation(m);
    if (status < 200 or status >= 300) {
        log.warn("book delete failed: {d}", .{status});
        return;
    }
    wi.global.unloadBook(m.old);
    if (wi.global.isGlobalSelected(m.old)) {
        _ = wi.global.toggleGlobal(m.old) catch false;
        reading_prefs.scheduleSave();
    }
    if (std.mem.eql(u8, open_file, m.old)) closeBook();
    reloadList();
}

/// No server rename route exists: save the loaded book under the new name, then delete the old
/// file. The book must be open (we need its parsed bytes to re-save).
pub fn renameBook() void {
    if (zx.platform.role != .client) return;
    if (open_char_book or open_file.len == 0) return;
    const book = wi.global.bookByFileId(open_file) orelse return;
    const name = promptString("Rename lorebook to:", open_file) orelse return;
    defer alloc.free(name);
    if (std.mem.eql(u8, name, open_file)) return;
    saveNowIfDirty();
    const m = startMutation(open_file, name) orelse return;
    const data = std.json.Stringify.valueAlloc(alloc, .{ .name = name, .data = book.root }, .{}) catch {
        freeMutation(m);
        return;
    };
    defer alloc.free(data);
    net.request("/api/worldinfo/edit", data, @intFromPtr(m), onRenameSaved, .{});
}

fn onRenameSaved(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const m = mutationFor(tag);
    if (status < 200 or status >= 300) {
        freeMutation(m);
        log.warn("rename save failed: {d}", .{status});
        return;
    }
    const body = std.json.Stringify.valueAlloc(alloc, .{ .name = m.old }, .{}) catch {
        freeMutation(m);
        return;
    };
    defer alloc.free(body);
    net.request("/api/worldinfo/delete", body, tag, onRenameDeleted, .{});
}

fn onRenameDeleted(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const m = mutationFor(tag);
    defer freeMutation(m);
    if (status < 200 or status >= 300) {
        log.warn("rename cleanup failed, both names exist: {d}", .{status});
    }
    wi.global.unloadBook(m.old);
    if (wi.global.isGlobalSelected(m.old)) {
        _ = wi.global.toggleGlobal(m.old) catch false;
        _ = wi.global.toggleGlobal(m.new) catch false;
        reading_prefs.scheduleSave();
    }
    reloadList();
    openBook(m.new);
}

// ---- import / export (browser-forced JS helpers, the char_api pattern) --------------------------

/// Import stays a JS helper: File/FormData cannot cross the wasm boundary.
pub fn importBookFile() void {
    if (zx.platform.role != .client) return;
    const ret = js.global.call(?js.Value, "__st_wi_import", .{}) catch {
        log.warn("wi import helper missing", .{});
        return;
    };
    if (ret) |r| r.deinit();
}

/// Export stays a JS helper: a blob download needs objectURL + a.click.
pub fn exportBook(file_id: []const u8) void {
    if (zx.platform.role != .client) return;
    const ret = js.global.call(?js.Value, "__st_wi_export", .{js.string(file_id)}) catch {
        log.warn("wi export helper missing", .{});
        return;
    };
    if (ret) |r| r.deinit();
}

// ---- scopes + budget -----------------------------------------------------------------------------

pub fn toggleGlobal(file_id: []const u8) void {
    _ = wi.global.toggleGlobal(file_id) catch |err| {
        log.warn("global toggle failed: {s}", .{@errorName(err)});
        return;
    };
    ensureScopeBooksLoaded(); // w3-wi-engine
    reading_prefs.scheduleSave();
    bump();
}

pub fn setBudget(raw: []const u8) void {
    const v = parseNum(raw) orelse return;
    wi.global.setBudget(v);
    reading_prefs.scheduleSave();
    bump();
}

// ---- scope-book loading for the engine (w3-wi-engine) --------------------------------------------

/// File ids with a /get in flight, so a scope re-check does not spam duplicate fetches.
var scope_fetches: std.ArrayList([]u8) = .empty;

/// Fetch every book the activation engine can reach (chat link, card link, global selection) that
/// is not loaded yet. The engine reads only loaded books at send time; this is what loads them.
/// Names resolve through the /list rows, so the list is (re)loaded first when absent.
pub fn ensureScopeBooksLoaded() void {
    if (zx.platform.role != .client) return;
    if (list_state == .idle) {
        reloadList();
        return; // onListDone re-enters once names are resolvable.
    }
    ensureBookLoaded(wi.global.chat_world);
    ensureBookLoaded(wi.global.char_world);
    for (wi.global.global_selected.items) |fid| ensureBookLoaded(fid);
}

fn ensureBookLoaded(ref: []const u8) void {
    const fid = wi.global.resolveRefFileId(ref) orelse return;
    if (wi.global.bookByFileId(fid) != null) return;
    for (scope_fetches.items) |f| {
        if (std.mem.eql(u8, f, fid)) return;
    }
    const body = std.json.Stringify.valueAlloc(alloc, .{ .name = fid }, .{}) catch return;
    defer alloc.free(body);
    const m = startMutation(fid, "") orelse return;
    const fid_c = alloc.dupe(u8, fid) catch {
        freeMutation(m);
        return;
    };
    scope_fetches.append(alloc, fid_c) catch {
        alloc.free(fid_c);
        freeMutation(m);
        return;
    };
    net.request("/api/worldinfo/get", body, @intFromPtr(m), onScopeBookDone, .{});
}

fn onScopeBookDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    const m = mutationFor(tag);
    defer freeMutation(m);
    for (scope_fetches.items, 0..) |f, i| {
        if (std.mem.eql(u8, f, m.old)) {
            alloc.free(f);
            _ = scope_fetches.swapRemove(i);
            break;
        }
    }
    if (res == null or status < 200 or status >= 300) {
        log.warn("scope book {s} fetch failed: {d}; it will not activate", .{ m.old, status });
        return;
    }
    const body = res.?.text() catch return;
    wi.global.loadBookFromJson(m.old, body) catch |err| {
        log.warn("scope book {s} unparseable: {s}", .{ m.old, @errorName(err) });
    };
}

// ---- the boot / card / chat seams ----------------------------------------------------------------

/// Boot hydration off the account settings blob (called from char_api after conn/config setFrom).
pub fn setFrom(settings_str: []const u8) void {
    wi.global.setFromSettings(settings_str);
    ensureScopeBooksLoaded();
}

/// reading_prefs' merge hook: write globalSelect + budget into the blob being saved.
pub fn mergeWorldInfo(a: std.mem.Allocator, root_obj: *std.json.ObjectMap) !void {
    try wi.global.mergeState(a, root_obj);
}

/// Card seam (char_api deep-card fetch): hand the raw card body to the store's one adoption
/// entry point (adoptCharCard), then reconcile the panel if the viewed embedded book vanished.
pub fn adoptCard(card_bytes: []const u8) void {
    wi.global.adoptCharCard(card_bytes);
    if (open_char_book and wi.global.char_book == null) closeBook();
    ensureScopeBooksLoaded(); // w3-wi-engine: the card may link a world by name
    bump();
}

/// The open chat's identity for the /api/chats/metadata write path (avatar + file). The FULL
/// change token the write gates on is pager's (w3-wi-engine): one owner shared with the note save
/// and the message mutations, so no writer stomps another's copy. Empty file = no chat to link.
var chat_avatar: []u8 = &.{};
var chat_file: []u8 = &.{};
var chat_link_in_flight = false;

/// Chat seam (chat open): adopt the chat's identity for the link write path, and its linked book
/// name from the metadata. An empty file clears both (no chat open).
pub fn setChatContext(avatar: []const u8, file_name: []const u8, chat_metadata: []const u8, full_token: []const u8) void {
    // The token parameter stays for call-site stability; pager owns the live copy (w3-wi-engine).
    _ = full_token;
    setOwned(&chat_avatar, avatar);
    setOwned(&chat_file, file_name);
    setChatWorldFromMetadata(chat_metadata);
    ensureScopeBooksLoaded();
}

pub fn chatOpen() bool {
    return chat_file.len > 0;
}

/// Link (or with "" unlink) a book to the open chat: POST /api/chats/metadata {world_info}, the
/// key the server's allowlist accepts since 9bc8ee713. The response token is adopted either way;
/// a 409 means another writer moved the file, so the user retries with the fresh token.
pub fn setChatBook(file_id: []const u8) void {
    if (zx.platform.role != .client) return;
    if (chat_file.len == 0 or chat_link_in_flight) return;
    const m = startMutation(file_id, "") orelse return;
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = chat_avatar,
        .file_name = chat_file,
        .change_token = pager.fullToken(),
        .world_info = file_id,
    }, .{}) catch {
        freeMutation(m);
        return;
    };
    defer alloc.free(body);
    chat_link_in_flight = true;
    net.request("/api/chats/metadata", body, @intFromPtr(m), onChatLinkDone, .{});
}

fn onChatLinkDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    const m = mutationFor(tag);
    defer freeMutation(m);
    chat_link_in_flight = false;
    adoptChatToken(res);
    if (status == 409) {
        save_status = "Chat changed elsewhere. Try again.";
        bump();
        return;
    }
    if (status < 200 or status >= 300) {
        save_status = "Chat link failed";
        log.warn("chat link failed: {d}", .{status});
        bump();
        return;
    }
    wi.global.setChatWorld(m.old);
    ensureScopeBooksLoaded();
    save_status = "Saved";
    bump();
}

/// The metadata response carries the post-save full token; without adopting it into the one owner
/// (pager) every later link, note save or message mutation would 409 on a stale copy.
fn adoptChatToken(res: ?*zx.Fetch.Response) void {
    const r = res orelse return;
    const parsed = r.json(std.json.Value) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const t = parsed.value.object.get("change_token") orelse return;
    if (t == .string and t.string.len > 0) pager.setFullToken(t.string);
}

/// Stock stores a plain string under `world_info`; newer blobs may wrap it in an object with a
/// name field.
fn setChatWorldFromMetadata(chat_metadata: []const u8) void {
    wi.global.setChatWorld("");
    defer bump();
    if (chat_metadata.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), chat_metadata, .{}) catch return;
    if (root != .object) return;
    const v = root.object.get("world_info") orelse return;
    switch (v) {
        .string => |s| wi.global.setChatWorld(s),
        .object => |o| {
            if (o.get("name")) |n| {
                if (n == .string) wi.global.setChatWorld(n.string);
            }
        },
        else => {},
    }
}

// ---- dialogs (Z-DIALOG, jsz reflection; the char_api pattern) ------------------------------------

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
