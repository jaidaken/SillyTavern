//! Zig-owned character/persona/chat data flows: boot orchestration, the character and
//! persona store loads, chat opening, and the CRUD posts, all through net.zig. Replaces the
//! deleted custom.js data layer (fetchCharacters/fetchPersonas/loadCharacterChat/
//! autoOpenRecentChat/charApiPost and the window.__st_char_* wrappers); Zig is the single
//! source of truth (ZX7). Only the browser-forced adapters stay in JS: multipart upload
//! (import, avatar), blob download (export), each reached via a thin window helper.
//!
//! zx-importing, so browser-verified via the interactions gate (ZX5); the pure parse and
//! shape logic lives in char_data.zig under `zig build test`.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const net = @import("./net.zig");
const data = @import("./char_data.zig");
const char_store = @import("./character_store.zig");
const character_view = @import("./character_view.zig");
const persona_store = @import("./persona_store.zig");
const store = @import("./store.zig");
const regions = @import("./regions.zig");
const dom_event = @import("./dom_event.zig");
const fixtures = @import("./fixtures.zig");

const alloc = char_store.page_gpa;
const chars_log = std.log.scoped(.chars);
const personas_log = std.log.scoped(.personas);
const boot_log = std.log.scoped(.boot);
const net_log = std.log.scoped(.net);

// ---- chat-load ticket -----------------------------------------------------------------

/// Ticket per chat load: the fetch is a window for a newer click, and a store rebuild makes
/// any in-flight load's captured index stale. Both bump the ticket; a completion whose tag
/// no longer matches abandons before touching the store (module-global per S1 probe a).
var chat_load_seq: u32 = 0;

// ---- boot orchestration ---------------------------------------------------------------

const BootOutcome = enum { ok, err, unreachable_backend };

var boot_demo = false;
var boot_pending: u8 = 0;
var boot_done = false;
var chars_outcome: BootOutcome = .err;

/// Boot entry, called once from bridge.bootInit: read ?demo from the location, seed the
/// fixtures in demo mode, then load characters and personas together. The auto-open (or the
/// unreachable-backend fallback) waits for BOTH loads so the seeded chat bakes the right
/// user avatar.
pub fn boot() void {
    if (zx.platform.role != .client) return;
    boot_demo = readDemoFlag();
    if (boot_demo) {
        seedDemoFixtures();
        boot_log.info("demo fixtures seeded (?demo)", .{});
    }
    boot_pending = 2;
    fetchCharacters();
    fetchPersonas();
}

fn readDemoFlag() bool {
    if (zx.platform.role != .client) return false;
    const loc = js.global.get(js.Object, "location") catch return false;
    defer loc.deinit();
    const search = loc.getAlloc(js.String, alloc, "search") catch return false;
    defer alloc.free(search);
    return data.hasQueryFlag(search, "demo");
}

fn seedDemoFixtures() void {
    fixtures.loadRoleplay(&store.global);
    regions.bumpMessageLog();
}

fn bootStep() void {
    if (boot_done) return;
    boot_pending -= 1;
    if (boot_pending > 0) return;
    boot_done = true;
    if (boot_demo) return;
    switch (chars_outcome) {
        .ok => autoOpenRecentChat(),
        // Demo fallback ONLY when nothing answered (network throw or dead-proxy 502/504);
        // a reachable backend's failure stays visible below, never masked by fixtures.
        .unreachable_backend => {
            seedDemoFixtures();
            boot_log.info("backend unreachable - demo fixtures seeded", .{});
        },
        .err => boot_log.err("character load failed against a reachable backend - see [st:net] above", .{}),
    }
}

// ---- characters ------------------------------------------------------------------------

/// Load /api/characters/all into the character store. Also the post-CRUD refresh, and the
/// target of the bridge's __st_refresh_characters export (the JS multipart helpers call it
/// after a successful upload).
pub fn fetchCharacters() void {
    if (zx.platform.role != .client) return;
    chars_log.debug("character load start", .{});
    net.request("/api/characters/all", "{}", 0, onCharactersDone, .{});
}

fn onCharactersDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    const outcome = loadCharacters(status, res);
    if (!boot_done) {
        chars_outcome = outcome;
        bootStep();
    }
}

fn loadCharacters(status: u16, res: ?*zx.Fetch.Response) BootOutcome {
    if (res == null or status == 0) {
        chars_log.err("character load failed: network error", .{});
        return .unreachable_backend;
    }
    if (status == 502 or status == 504) {
        net_log.warn("char fetch: upstream gone, {d}", .{status});
        return .unreachable_backend;
    }
    if (status < 200 or status >= 300) {
        net_log.warn("char fetch failed: {d}", .{status});
        return .err;
    }
    // A reachable 200 with a malformed body is an ERROR, never the demo fallback: the
    // backend answered, so its brokenness must stay visible.
    const parsed = res.?.json([]data.CharacterJson) catch |err| {
        net_log.warn("char list response is not a character array: {s}", .{@errorName(err)});
        return .err;
    };
    defer parsed.deinit();
    rebuildCharacterStore(parsed.value) catch |err| {
        chars_log.err("character store rebuild failed: {s}", .{@errorName(err)});
        return .err;
    };
    chars_log.info("loaded {d} characters", .{parsed.value.len});
    return .ok;
}

fn rebuildCharacterStore(list: []const data.CharacterJson) !void {
    char_store.global.clear();
    // Store rebuild invalidates any in-flight chat load: its captured index is now stale.
    chat_load_seq +%= 1;
    for (list) |cj| try appendCharacter(cj);
    recomputeView();
}

fn appendCharacter(cj: data.CharacterJson) !void {
    // Copies out of the json Parsed arena into the store's allocator (Z97: the Parsed is
    // deinited right after this loop).
    const name = try alloc.dupe(u8, cj.name);
    errdefer alloc.free(name);
    const avatar = try alloc.dupe(u8, cj.avatar);
    errdefer alloc.free(avatar);
    const desc = try alloc.dupe(u8, cj.description);
    errdefer alloc.free(desc);
    const chat = try alloc.dupe(u8, cj.chat);
    errdefer alloc.free(chat);
    const first_mes = try alloc.dupe(u8, cj.first_mes);
    errdefer alloc.free(first_mes);
    const create_date = try alloc.dupe(u8, cj.create_date);
    errdefer alloc.free(create_date);
    try char_store.global.append(.{
        .name = name,
        .avatar = avatar,
        .description = desc,
        .personality = "",
        .scenario = "",
        .mes_example = "",
        .chat = chat,
        .first_mes = first_mes,
        .fav = data.favTruthy(cj.fav),
        .tags = &.{},
        .create_date = create_date,
        .date_last_chat = data.metaU64(cj.date_last_chat),
        .chat_size = data.metaU64(cj.chat_size),
        .data_size = data.metaU64(cj.data_size),
        .name_owned = if (name.len > 0) name else null,
        .avatar_owned = if (avatar.len > 0) avatar else null,
        .description_owned = if (desc.len > 0) desc else null,
        .chat_owned = if (chat.len > 0) chat else null,
        .first_mes_owned = if (first_mes.len > 0) first_mes else null,
        .create_date_owned = if (create_date.len > 0) create_date else null,
    });
}

fn recomputeView() void {
    character_view.global.compute(char_store.global.slice()) catch |err| {
        chars_log.err("character view compute failed: {s}", .{@errorName(err)});
    };
    regions.bumpShell();
}

fn autoOpenRecentChat() void {
    const chars = char_store.slice();
    const best = data.mostRecentIndex(chars) orelse {
        chars_log.debug("auto-open: no characters", .{});
        return;
    };
    chars_log.info("auto-opening most recent chat: {s}", .{chars[best].name});
    loadCharacterChat(best);
}

// ---- personas ---------------------------------------------------------------------------

fn fetchPersonas() void {
    personas_log.debug("persona load start", .{});
    net.request("/api/settings/get", "{}", 0, onPersonasDone, .{});
}

fn onPersonasDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    loadPersonas(status, res);
    bootStep();
}

fn loadPersonas(status: u16, res: ?*zx.Fetch.Response) void {
    if (res == null or status == 0) {
        personas_log.err("persona load failed: network error", .{});
        return;
    }
    if (status < 200 or status >= 300) {
        net_log.warn("persona settings fetch returned {d}", .{status});
        return;
    }
    const parsed = res.?.json(data.SettingsJson) catch {
        personas_log.warn("settings response is not an object", .{});
        return;
    };
    defer parsed.deinit();
    const settings_str = parsed.value.settings orelse {
        personas_log.warn("settings.settings is not a string", .{});
        return;
    };
    const list = data.extractPersonas(alloc, settings_str) catch |err| {
        switch (err) {
            error.ParseFailed => personas_log.warn("settings JSON parse failed", .{}),
            error.NotAnObject => personas_log.warn("parsed settings is not an object", .{}),
            error.OutOfMemory => personas_log.err("persona load failed: OutOfMemory", .{}),
        }
        return;
    };
    defer data.freePersonas(alloc, list);
    persona_store.global.clear();
    for (list) |p| {
        appendPersona(p) catch |err| {
            personas_log.err("add persona: {s}, persona dropped", .{@errorName(err)});
        };
    }
    regions.bumpShell();
}

fn appendPersona(p: data.PersonaJson) !void {
    const name = try alloc.dupe(u8, p.name);
    errdefer alloc.free(name);
    const avatar = try alloc.dupe(u8, p.avatar);
    errdefer alloc.free(avatar);
    const desc = try alloc.dupe(u8, p.description);
    errdefer alloc.free(desc);
    try persona_store.global.append(.{
        .name = name,
        .avatar = avatar,
        .description = desc,
        .name_owned = name,
        .avatar_owned = avatar,
        .description_owned = desc,
    });
}

/// Persona used for the user side of a chat: the explicit selection when there is one,
/// else the first persona (the deleted glue always used the first; preferring a live
/// selection is the Zig-ownership improvement over that).
fn activePersona() ?persona_store.Persona {
    if (persona_store.selected()) |p| return p;
    const s = persona_store.slice();
    if (s.len > 0) return s[0];
    return null;
}

// ---- chat load ---------------------------------------------------------------------------

/// Open the chat for the character at `index` (store order). Sequenced by the chat-load
/// ticket; sets aria-busy on #chat for the duration; an error status keeps the current view;
/// the greeting is seeded only on a true 200-empty response.
pub fn loadCharacterChat(index: usize) void {
    if (zx.platform.role != .client) return;
    const chars = char_store.slice();
    if (index >= chars.len) {
        chars_log.warn("load chat: no character at index {d} of {d}", .{ index, chars.len });
        return;
    }
    const c = chars[index];
    chars_log.debug("load chat request: index {d} {s}", .{ index, c.name });
    chat_load_seq +%= 1;
    const file_name = chatFileName(c) orelse return;
    defer alloc.free(file_name);
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = c.avatar,
        .file_name = file_name,
    }, .{}) catch return;
    defer alloc.free(body);
    // Busy only once the request actually dispatches, so an alloc-failure return above
    // cannot leave #chat stuck aria-busy.
    setChatBusy(true);
    // The tag carries both the ticket and the index, so the completion knows exactly which
    // request it answers even with two loads in flight.
    const tag: u64 = (@as(u64, index) << 32) | chat_load_seq;
    net.request("/api/chats/get", body, tag, onChatDone, .{});
}

fn chatFileName(c: char_store.Character) ?[]u8 {
    if (c.chat.len > 0) return alloc.dupe(u8, c.chat) catch null;
    // Old-glue fallback: "<name> - <today>" with today's UTC date from Date.now via jsz.
    var buf: [10]u8 = undefined;
    const iso = data.isoDateFromMs(nowMs(), &buf);
    return std.fmt.allocPrint(alloc, "{s} - {s}", .{ c.name, iso }) catch null;
}

fn nowMs() f64 {
    if (zx.platform.role != .client) return 0;
    const date_ctor = js.global.get(js.Object, "Date") catch return 0;
    defer date_ctor.deinit();
    return date_ctor.call(f64, "now", .{}) catch 0;
}

fn onChatDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    const seq: u32 = @truncate(tag);
    const index: usize = @intCast(tag >> 32);
    if (seq != chat_load_seq) {
        // A newer load (or a store rebuild) owns the ticket and the aria-busy flag now.
        chars_log.debug("load chat: superseded mid-fetch, abandoning", .{});
        return;
    }
    defer setChatBusy(false);
    const chars = char_store.slice();
    if (index >= chars.len) {
        chars_log.warn("load chat: character index {d} vanished", .{index});
        return;
    }
    const c = chars[index];
    if (res == null or status == 0) {
        chars_log.err("chat load failed: network error", .{});
        return;
    }
    // Server contract: 200 [] / 200 {} = no chat yet (seed the greeting below); any error
    // status = the chat may exist but could not be read - keep the current view.
    if (status < 200 or status >= 300) {
        chars_log.err("chat fetch failed: {d} - keeping current chat", .{status});
        return;
    }
    const parsed = res.?.json(std.json.Value) catch {
        chars_log.err("chat load failed: malformed body - keeping current chat", .{});
        return;
    };
    defer parsed.deinit();
    const msgs = data.chatMessages(alloc, parsed.value) catch |err| {
        chars_log.err("chat load failed: {s} - keeping current chat", .{@errorName(err)});
        return;
    };
    defer data.freeChatMessages(alloc, msgs);

    store.global.clear();
    char_store.global.select(index);

    const char_avatar: ?[]u8 = if (c.avatar.len > 0) data.thumbUrl(alloc, "avatar", c.avatar) catch null else null;
    defer if (char_avatar) |u| alloc.free(u);
    const persona = activePersona();
    const persona_avatar: ?[]u8 = if (persona) |p|
        (if (p.avatar.len > 0) data.thumbUrl(alloc, "persona", p.avatar) catch null else null)
    else
        null;
    defer if (persona_avatar) |u| alloc.free(u);

    if (msgs.len > 0) {
        for (msgs) |m| {
            const sender = if (m.name.len > 0) m.name else if (m.is_user) "You" else c.name;
            const avatar = if (m.is_user) (persona_avatar orelse "") else (char_avatar orelse "");
            store.global.appendCopy(sender, m.mes, avatar) catch |err| {
                chars_log.err("append message: {s}, message dropped", .{@errorName(err)});
            };
        }
    } else if (c.first_mes.len > 0) {
        const user_name = if (persona) |p| p.name else "You";
        if (data.renderGreeting(alloc, c.first_mes, c.name, user_name)) |greeting| {
            defer alloc.free(greeting);
            store.global.appendCopy(c.name, greeting, char_avatar orelse "") catch |err| {
                chars_log.err("append greeting: {s}", .{@errorName(err)});
            };
            chars_log.debug("seeded greeting for {s}", .{c.name});
        } else |err| {
            chars_log.err("greeting render failed: {s}", .{@errorName(err)});
        }
    }
    regions.bumpMessageLog();
    regions.bumpShell();
    chars_log.info("opened chat: {s} ({d} messages)", .{ c.name, msgs.len });
    // The bumps above re-rendered synchronously (S1 probe finding d), so the newest message
    // is in the DOM; land on it (upstream ST behavior).
    scrollChatToNewest();
}

fn setChatBusy(busy: bool) void {
    const el = dom_event.elementById(alloc, "chat") orelse return;
    defer el.deinit();
    if (busy) el.setAttribute("aria-busy", "true") else el.removeAttribute("aria-busy");
}

fn scrollChatToNewest() void {
    if (zx.platform.role != .client) return;
    const doc = js.global.get(js.Object, "document") catch return;
    defer doc.deinit();
    // :last-child cannot match here (the resize handle is the chat container's last child),
    // so take the last of the .mes NodeList.
    const list = doc.call(js.Object, "querySelectorAll", .{js.string("#chat .mes")}) catch return;
    defer list.deinit();
    const len = list.get(u32, "length") catch return;
    if (len == 0) return;
    const el = list.call(js.Object, "item", .{len - 1}) catch return;
    defer el.deinit();
    // scrollIntoView(false) aligns the bottom edge: the boolean form of {block:'end'}.
    el.call(void, "scrollIntoView", .{false}) catch return;
}

// ---- character CRUD ------------------------------------------------------------------------

/// New character via window.prompt (jsz reflection, S1 probe finding f); cancel aborts.
pub fn createCharacter() void {
    if (zx.platform.role != .client) return;
    const name = promptString("New character name:", "") orelse return;
    defer alloc.free(name);
    const body = std.json.Stringify.valueAlloc(alloc, .{ .ch_name = name }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/characters/create", body, 0, onCreateDone, .{});
}

pub fn renameCharacter(index: usize) void {
    if (zx.platform.role != .client) return;
    const c = charAt(index) orelse return;
    const name = promptString("Rename character:", c.name) orelse return;
    defer alloc.free(name);
    if (std.mem.eql(u8, name, c.name)) return;
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = c.avatar,
        .new_name = name,
    }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/characters/rename", body, 0, onRenameDone, .{});
}

pub fn duplicateCharacter(index: usize) void {
    if (zx.platform.role != .client) return;
    const c = charAt(index) orelse return;
    const body = std.json.Stringify.valueAlloc(alloc, .{ .avatar_url = c.avatar }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/characters/duplicate", body, 0, onDuplicateDone, .{});
}

pub fn deleteCharacter(index: usize) void {
    if (zx.platform.role != .client) return;
    const c = charAt(index) orelse return;
    const msg = std.fmt.allocPrint(alloc, "Delete \"{s}\"? This cannot be undone.", .{c.name}) catch return;
    defer alloc.free(msg);
    if (!confirmDialog(msg)) return;
    const body = std.json.Stringify.valueAlloc(alloc, .{ .avatar_url = c.avatar }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/characters/delete", body, 0, onDeleteDone, .{});
}

/// Favourite toggle. Deliberately NOT optimistic: the star flips only when the refetch
/// lands (old-glue parity). An optimistic flip renders early, lets the UI race ahead of
/// the in-flight refetch, and that refetch's store rebuild then bumps the chat-load ticket
/// under whatever chat open the user started meanwhile (caught live by gate row B8a).
pub fn toggleFav(index: usize) void {
    if (zx.platform.role != .client) return;
    const c = charAt(index) orelse return;
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = c.avatar,
        .field = "fav",
        .value = !c.fav,
    }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/characters/edit-attribute", body, 0, onFavDone, .{});
}

fn onFavDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (status >= 200 and status < 300) {
        fetchCharacters();
        return;
    }
    net_log.warn("/api/characters/edit-attribute failed: {d}", .{status});
}

fn onCreateDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    crudRefresh("create", status);
}
fn onRenameDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    crudRefresh("rename", status);
}
fn onDuplicateDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    crudRefresh("duplicate", status);
}
fn onDeleteDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    crudRefresh("delete", status);
}

fn crudRefresh(action: []const u8, status: u16) void {
    if (status < 200 or status >= 300) {
        net_log.warn("character {s} failed: {d}", .{ action, status });
        return;
    }
    fetchCharacters();
}

// ---- browser-forced adapters (thin JS helpers) ----------------------------------------------

/// Export stays a JS helper: a blob download needs objectURL + a.click. Zig hands it the
/// avatar and the display name (the old helper looked both up in the deleted jsCharacters).
pub fn exportCharacter(index: usize) void {
    if (zx.platform.role != .client) return;
    const c = charAt(index) orelse return;
    js.global.call(void, "__st_char_export", .{ js.string(c.avatar), js.string(c.name) }) catch {
        chars_log.warn("export helper missing", .{});
    };
}

/// Import stays a JS helper: File/FormData cannot cross the wasm boundary.
pub fn importCharacterFile() void {
    if (zx.platform.role != .client) return;
    js.global.call(void, "__st_char_import", .{}) catch {
        chars_log.warn("import helper missing", .{});
    };
}

/// Avatar replacement stays a JS helper for the same multipart reason.
pub fn replaceAvatarFile(index: usize) void {
    if (zx.platform.role != .client) return;
    const c = charAt(index) orelse return;
    js.global.call(void, "__st_char_avatar", .{js.string(c.avatar)}) catch {
        chars_log.warn("avatar helper missing", .{});
    };
}

// ---- dialogs (Z-DIALOG, jsz reflection) ------------------------------------------------------

/// window.prompt; JS null (cancel) and the empty string both come back as null, matching
/// the old `if (!name) return` guards.
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

// ---- helpers ---------------------------------------------------------------------------------

fn charAt(index: usize) ?char_store.Character {
    const chars = char_store.slice();
    if (index >= chars.len) return null;
    return chars[index];
}
