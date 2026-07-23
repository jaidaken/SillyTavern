//! The backgrounds feature: the gallery fetch, the chosen image, and its persistence. The sibling of
//! appearance.zig (chrome colours) and reading_prefs.zig (the reading surface); this owns the image
//! behind them.
//!
//! The choice lives in three places and this module keeps them in step: localStorage
//! (`st-background`, the fast source that paints before any network round trip), two properties on
//! the document root (`--chat-bg-image` carries the url, `data-background` gates the layer on), and
//! the account settings blob (`clientBackground`, written through reading_prefs' single debounced
//! saver so two independent full-replace saves can never clobber the blob).
//!
//! INVARIANT 6: a background is chrome BEHIND the reading surface. The layer is a body::before
//! fixed under the content, and nothing here reaches .mes_text. The gallery is server-authoritative:
//! a delete or rename mutates the local list only after the server says it took, so a refused write
//! can never leave a stale tile reading as success (WD56).
//!
//! zx-importing, so it is browser-verified through the interaction gate (ZX5), not `zig build test`;
//! the pure model it leans on is background_store.zig.

const std = @import("std");
const zx = @import("zx");
const notifications = @import("./notifications.zig");
const js = zx.client.js;

const bg = @import("./background_store.zig");
const net = @import("./net.zig");
const uploads = @import("./uploads.zig");
const char_store = @import("./character_store.zig");
const reading_prefs = @import("./reading_prefs.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.panels);

/// The chosen filename. "" (absent) means no background, which is the shipped default.
const bg_key = "st-background";

/// The four states every async surface designs (WD54). `idle` has not asked yet: the gallery loads
/// when the drawer first opens, not at boot, because most sessions never open it.
pub const LoadState = enum { idle, loading, ready, failed };

var load_state: LoadState = .idle;
var gallery: bg.List = .{};
var last_error: []u8 = &.{};

/// One mutation on the wire. net.zig's callback carries only a u64 tag, so the names the callback
/// must act on ride that tag as the mutation's own address, and each one is independent: a second
/// delete while the first is still in flight is a real request, not a click swallowed in silence.
///
/// A single shared slot used to park these, guarded by `if (pending.len > 0) return;` BEFORE the
/// dialog. The dialog was read as making that unreachable, but it does not: it blocks only while it
/// is up, and the request outlives it, so a second delete during the in-flight window returned
/// early and the user got no dialog, no error, and no delete.
const Mutation = struct {
    old: []u8,
    new: []u8,
};

/// The mutation, or null when the client cannot afford it. Its address is the tag.
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

/// Safe on one invariant: net.zig passes a tag back UNTOUCHED on every path, the three early
/// failures included (net.zig:72,76,81 `on_done(tag, 0, null)`; :165 replays the stored one). So the
/// only tag that reaches here is one startMutation minted. Both callbacks are private and both call
/// sites are a few lines away: keep it that way, because this deref cannot check its own input.
fn mutationFor(tag: u64) *Mutation {
    return @ptrFromInt(@as(usize, @intCast(tag)));
}

fn endMutation(m: *Mutation) void {
    alloc.free(m.old);
    alloc.free(m.new);
    alloc.destroy(m);
}

/// The panel's render handle, published on its first render. It lives here rather than in
/// regions.zig because backgrounds_body.zx is its only consumer and this module its only bumper.
pub var region: ?*zx.State(u32) = null;

fn bump() void {
    if (region) |h| h.set(h.get() +% 1);
}

// ---- render reads ------------------------------------------------------------------------------

pub fn state() LoadState {
    return load_state;
}

pub fn list() []const bg.Background {
    return gallery.slice();
}

pub fn errorText() []const u8 {
    return last_error;
}

/// The chosen filename, or "" for none. Allocated on `a` (the render allocator).
pub fn selected(a: std.mem.Allocator) []const u8 {
    return getItem(a, bg_key) orelse "";
}

/// The gallery tile's thumbnail src. Allocated on `a`; an OOM yields "" so the tile renders
/// imageless rather than failing the whole panel.
pub fn thumbFor(a: std.mem.Allocator, filename: []const u8) []const u8 {
    return bg.thumbUrl(a, filename) catch "";
}

// ---- localStorage (jsz two-step per T2: window things come off js.global) ----------------------

fn localStorage() ?js.Object {
    if (zx.platform.role != .client) return null;
    return js.global.get(js.Object, "localStorage") catch {
        log.warn("localStorage unavailable", .{});
        return null;
    };
}

/// Caller frees. An absent or empty value reads as null so callers fall back to no background.
fn getItem(a: std.mem.Allocator, key: []const u8) ?[]u8 {
    if (zx.platform.role != .client) return null;
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
    if (zx.platform.role != .client) return;
    const ls = localStorage() orelse return;
    defer ls.deinit();
    ls.call(void, "setItem", .{ js.string(key), js.string(value) }) catch {
        log.warn("localStorage write refused: {s}", .{key});
    };
}

fn removeItem(key: []const u8) void {
    if (zx.platform.role != .client) return;
    const ls = localStorage() orelse return;
    defer ls.deinit();
    ls.call(void, "removeItem", .{js.string(key)}) catch {};
}

// ---- the document-root properties the layer reads ----------------------------------------------

/// The document root (:root / <html>). Caller deinits.
fn rootEl() ?js.Object {
    if (zx.platform.role != .client) return null;
    const doc = js.global.get(js.Object, "document") catch return null;
    defer doc.deinit();
    return doc.get(js.Object, "documentElement") catch null;
}

/// Publish the image to the CSS layer. The url rides a custom property (a url cannot live in an
/// attribute selector); `data-background` gates the pseudo-element on, so an unset background costs
/// no scrim over the chrome.
fn applyImage(filename: []const u8) void {
    if (zx.platform.role != .client) return;
    const root = rootEl() orelse return;
    defer root.deinit();

    const prop = bg.imageProp(alloc, filename) catch return;
    defer alloc.free(prop);

    const style = root.get(js.Object, "style") catch return;
    defer style.deinit();
    style.call(void, "setProperty", .{ js.string("--chat-bg-image"), js.string(prop) }) catch {
        log.warn("could not set the background image", .{});
        return;
    };
    if (filename.len == 0) {
        root.call(void, "removeAttribute", .{js.string("data-background")}) catch {};
    } else {
        root.call(void, "setAttribute", .{ js.string("data-background"), js.string("on") }) catch {};
    }
}

// ---- boot apply --------------------------------------------------------------------------------

/// The stored background onto the document root. Called at boot from bridge.bootInit, so a chosen
/// image paints with the first frame instead of appearing a beat later.
pub fn applyAll() void {
    if (zx.platform.role != .client) return;
    const stored = getItem(alloc, bg_key);
    defer if (stored) |s| alloc.free(s);
    applyImage(stored orelse "");
    log.debug("background applied", .{});
}

// ---- the gallery fetch -------------------------------------------------------------------------

/// Load the gallery once, on the panel's first render. Idempotent: a second call while a load is in
/// flight, or after one succeeded, does nothing.
pub fn ensureLoaded() void {
    if (zx.platform.role != .client) return;
    if (load_state != .idle) return;
    load_state = .loading;
    net.request("/api/backgrounds/all", "{}", 0, onList, .{});
}

/// Re-fetch the gallery: the retry the error state offers, and the refresh after a mutation.
pub fn reload() void {
    if (zx.platform.role != .client) return;
    if (load_state == .loading) return;
    clearError();
    load_state = .loading;
    bump();
    net.request("/api/backgrounds/all", "{}", 0, onList, .{});
}

fn onList(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (res == null or status < 200 or status >= 300) {
        load_state = .failed;
        setError("The backgrounds could not be loaded ({d}).", .{status});
        bump();
        return;
    }
    const parsed = res.?.json(bg.AllResponse) catch {
        load_state = .failed;
        setError("The backgrounds list came back in a shape this client does not read.", .{});
        bump();
        return;
    };
    defer parsed.deinit();
    gallery.replace(alloc, parsed.value.images) catch {
        load_state = .failed;
        setError("The backgrounds list did not fit in memory.", .{});
        bump();
        return;
    };
    load_state = .ready;
    clearError();
    log.debug("backgrounds loaded: {d}", .{gallery.slice().len});
    bump();
}

// ---- the click paths ---------------------------------------------------------------------------

/// Choose a background, or clear it with "". Persists, paints, and queues the account save.
pub fn select(filename: []const u8) void {
    if (zx.platform.role != .client) return;
    if (filename.len == 0) removeItem(bg_key) else setItem(bg_key, filename);
    applyImage(filename);
    reading_prefs.scheduleSave();
    bump();
    log.debug("background = {s}", .{filename});
}

/// Delete a background file. Server-authoritative: the tile goes only once the server confirms, so a
/// refused delete leaves the gallery honest (WD56).
pub fn deleteBg(filename: []const u8) void {
    if (zx.platform.role != .client) return;
    const msg = std.fmt.allocPrint(alloc, "Delete background \"{s}\"? This cannot be undone.", .{filename}) catch return;
    defer alloc.free(msg);
    if (!confirmDialog(msg)) return;

    const body = std.json.Stringify.valueAlloc(alloc, .{ .bg = filename }, .{}) catch return;
    defer alloc.free(body);
    const m = startMutation(filename, "") orelse {
        setError("\"{s}\" could not be deleted: the client is out of memory.", .{filename});
        bump();
        return;
    };
    net.request("/api/backgrounds/delete", body, @intFromPtr(m), onDeleted, .{});
}

fn onDeleted(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const m = mutationFor(tag);
    defer endMutation(m);
    if (status < 200 or status >= 300) {
        setError("\"{s}\" could not be deleted ({d}). It is still on the server.", .{ m.old, status });
        notifications.pushFmt(.err, notifications.error_ttl_ms, "Background delete failed: {d}", .{status});
        bump();
        return;
    }
    _ = gallery.remove(alloc, m.old);
    clearSelectionIf(m.old);
    clearError();
    bump();
}

/// Rename a background file. Server-authoritative for the same reason as delete; the server refuses
/// a name that already exists, and that refusal has to reach the user rather than a renamed tile.
pub fn renameBg(filename: []const u8) void {
    if (zx.platform.role != .client) return;
    const name = promptString("Rename background:", filename) orelse return;
    defer alloc.free(name);
    if (std.mem.eql(u8, name, filename)) return;

    const body = std.json.Stringify.valueAlloc(alloc, .{ .old_bg = filename, .new_bg = name }, .{}) catch return;
    defer alloc.free(body);
    const m = startMutation(filename, name) orelse {
        setError("\"{s}\" could not be renamed: the client is out of memory.", .{filename});
        bump();
        return;
    };
    net.request("/api/backgrounds/rename", body, @intFromPtr(m), onRenamed, .{});
}

fn onRenamed(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const m = mutationFor(tag);
    defer endMutation(m);
    const old = m.old;
    const new = m.new;
    if (status < 200 or status >= 300) {
        setError("\"{s}\" could not be renamed ({d}). A background of that name may already exist.", .{ old, status });
        notifications.pushFmt(.err, notifications.error_ttl_ms, "Background rename failed: {d}", .{status});
        bump();
        return;
    }
    _ = gallery.rename(alloc, old, new) catch {
        // The file moved on the server, so the list is the stale copy: re-fetch rather than guess.
        reload();
        return;
    };
    const sel = getItem(alloc, bg_key);
    defer if (sel) |s| alloc.free(s);
    if (sel != null and std.mem.eql(u8, sel.?, old)) select(new);
    clearError();
    bump();
}

fn clearSelectionIf(filename: []const u8) void {
    const sel = getItem(alloc, bg_key) orelse return;
    defer alloc.free(sel);
    if (std.mem.eql(u8, sel, filename)) select("");
}

// ---- upload ------------------------------------------------------------------------------------

/// The upload's own state, kept apart from the gallery's: a refused upload must not blank a gallery
/// that loaded perfectly well.
pub const UploadState = enum { idle, sending, failed };

var upload_state: UploadState = .idle;
var upload_error: []u8 = &.{};

pub fn uploadState() UploadState {
    return upload_state;
}

pub fn uploadErrorText() []const u8 {
    return upload_error;
}

/// Post the file the user just picked. uploads.zig reads the input to bytes, builds the multipart in
/// Zig and posts it; this draws the wait and hands off. Driven by the input's change event, so a file
/// is present by the time it runs (a cancelled picker settles back through onUploadDone).
pub fn uploadPick() void {
    if (zx.platform.role != .client) return;
    if (upload_state == .sending) return;
    upload_state = .sending;
    clearErrorOn(&upload_error);
    bump();
    uploads.start(.{ .input_id = "bg-upload-input", .url = "/api/backgrounds/upload", .on_done = onUploadDone });
}

/// uploads.zig's answer. A 2xx means the file landed and the gallery re-fetches to show it (the
/// server names the file from its own upload, so only the server knows what it ended up called);
/// anything else is the status seen, with 0 for a request that never completed or a cancelled picker.
fn onUploadDone(status: u16, sent: bool) void {
    _ = sent;
    if (status >= 200 and status < 300) {
        upload_state = .idle;
        clearErrorOn(&upload_error);
        notifications.push(.success, "Background uploaded", notifications.default_ttl_ms);
        reload();
        return;
    }
    notifications.pushFmt(.err, notifications.error_ttl_ms, "Background upload failed: {d}", .{status});
    upload_state = .failed;
    if (status == 0) {
        setErrorOn(&upload_error, "The upload did not reach the server. The file was not added.", .{});
    } else {
        setErrorOn(&upload_error, "The upload was refused ({d}). The file was not added.", .{status});
    }
    bump();
}

// ---- the account-settings save -----------------------------------------------------------------

/// Write the chosen background into the settings object reading_prefs is about to save. Called from
/// reading_prefs.mergedSettings on every save, so the choice follows the account rather than the
/// browser. Always written, including the empty "none", so clearing a background persists as a
/// choice rather than reading as an absent key.
pub fn mergeState(a: std.mem.Allocator, root_obj: *std.json.ObjectMap) !void {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "image", .{ .string = getItem(a, bg_key) orelse "" });
    try root_obj.put(a, "clientBackground", .{ .object = obj });
}

// ---- error surface -----------------------------------------------------------------------------

/// The gallery and the upload each own their message. Sharing one slot would let a refused upload
/// overwrite the reason the gallery is empty, and render the same sentence in both alerts at once.
fn setErrorOn(slot: *[]u8, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch return;
    if (slot.len > 0) alloc.free(slot.*);
    slot.* = msg;
    log.warn("{s}", .{msg});
}

fn clearErrorOn(slot: *[]u8) void {
    if (slot.len == 0) return;
    alloc.free(slot.*);
    slot.* = &.{};
}

fn setError(comptime fmt: []const u8, args: anytype) void {
    setErrorOn(&last_error, fmt, args);
}

fn clearError() void {
    clearErrorOn(&last_error);
}

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
