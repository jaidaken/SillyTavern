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
const generate = @import("./generate.zig");
const templates = @import("./templates.zig");
const authors_note = @import("./authors_note.zig");
const an_state = @import("./authors_note_state.zig");
const config_state = @import("./config_state.zig");
const conn_mod = @import("./connection.zig");
const char_store = @import("./character_store.zig");
const character_view = @import("./character_view.zig");
const persona_store = @import("./persona_store.zig");
const persona_actions = @import("./persona_actions.zig");
const store = @import("./store.zig");
const wi_actions = @import("./world_info_actions.zig"); // w3-wi
const pager = @import("./pager.zig");
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

/// The seq of the in-flight re-sync reload, so ONLY its completion restores the reader's anchor. A bare
/// bool leaks across an interleaved normal open (it cannot tell which load is the re-sync); keying to the
/// seq means a normal open never inherits the marker and a second re-sync overwrites it.
var resync_seq: ?u32 = null;

// ---- send-loop state ------------------------------------------------------------------

// The active backend connection lives in connection.zig; the send loop reads it via conn_mod.active().

/// The selected card's deep fields (personality/scenario/mesExamples), which the shallow
/// /api/characters/all form does not carry. Fetched once per card on open via /api/characters/get,
/// keyed by `deep_avatar`; the prompt reuses them for every send with no per-send refetch.
var deep_avatar: []u8 = &.{};
var deep_pending: []u8 = &.{};
var deep_personality: []u8 = &.{};
var deep_scenario: []u8 = &.{};
var deep_mes_example: []u8 = &.{};
var deep_in_flight: bool = false;

/// Captured at send so the seal-time assistant append targets the chat the send opened against, even
/// if the selection changed during the seconds-long generation.
var send_avatar: []u8 = &.{};
var send_file: []u8 = &.{};
/// The chat-load ticket at send time. A resync (a 409 append, or the user opening another chat) bumps
/// it mid-generation, so the seal-time assistant append checks it and skips a now-stale target.
var send_seq: u32 = 0;

// ---- pending send (invariant 2) -------------------------------------------------------------

// net has no per-request ctx: the send context is stashed OWNED and consumed by onPromptWindowDone.
var pend_active: bool = false;
var pend_conn: ?generate.Connection = null;
var pend_char_name: []u8 = &.{};
var pend_char_avatar: []u8 = &.{};
var pend_user_name: []u8 = &.{};
var pend_user_text: []u8 = &.{};
var pend_persona_desc: []u8 = &.{};
var pend_description: []u8 = &.{};
var pend_personality: []u8 = &.{};
var pend_scenario: []u8 = &.{};
var pend_mes_example: []u8 = &.{};
var pend_first_mes: []u8 = &.{};

fn setOwned(dst: *[]u8, src: []const u8) void {
    if (dst.len > 0) alloc.free(dst.*);
    dst.* = alloc.dupe(u8, src) catch &.{};
}

/// Dupes the connection's URLs into pending ownership so a boot re-mine or a Connect mid-fetch cannot
/// free them under the in-flight prompt build. False on OOM of either URL.
fn stashConn(conn: generate.Connection) bool {
    const t = alloc.dupe(u8, conn.api_type) catch return false;
    const s = alloc.dupe(u8, conn.api_server) catch {
        alloc.free(t);
        return false;
    };
    if (pend_conn) |c| generate.freeConnection(alloc, c);
    pend_conn = .{
        .api_type = t,
        .api_server = s,
        .max_context = conn.max_context,
        .max_tokens = conn.max_tokens,
        .temperature = conn.temperature,
        .top_p = conn.top_p,
        .top_k = conn.top_k,
        .min_p = conn.min_p,
        .rep_pen = conn.rep_pen,
    };
    return true;
}

/// The send's OWN copy of the templates and the chat's author's note, in an arena this file owns.
///
/// A send is not instant: the prompt window is a fetch RTT, and a settings re-mine or a template
/// edit during it frees the live set (config_state swaps its arena) under the in-flight build. So the
/// templates are duped at stash time exactly as stashConn dupes the connection's URLs, and the arena
/// is dropped in freePending.
var pend_tpl_arena: ?std.heap.ArenaAllocator = null;
var pend_tpl: templates.Templates = .{};
var pend_note: authors_note.Note = .{};

fn stashTemplates(t: templates.Templates) bool {
    var arena = std.heap.ArenaAllocator.init(alloc);
    const duped = templates.dupeTemplates(arena.allocator(), t) catch {
        arena.deinit();
        return false;
    };
    if (pend_tpl_arena) |*a| a.deinit();
    pend_tpl_arena = arena;
    pend_tpl = duped;
    return true;
}

/// The send's own copy of the note, into the same arena as the templates: the panel can edit the
/// prompt during the window fetch, which frees the live string under the in-flight build.
fn stashNote() bool {
    const live = an_state.active();
    const arena = (if (pend_tpl_arena) |*a| a else return false).allocator();
    pend_note = live;
    pend_note.prompt = arena.dupe(u8, live.prompt) catch return false;
    return true;
}

fn freePending() void {
    if (pend_conn) |c| {
        generate.freeConnection(alloc, c);
        pend_conn = null;
    }
    if (pend_tpl_arena) |*a| {
        a.deinit();
        pend_tpl_arena = null;
    }
    pend_tpl = .{};
    pend_note = .{};
    inline for (.{ &pend_char_name, &pend_char_avatar, &pend_user_name, &pend_user_text, &pend_persona_desc, &pend_description, &pend_personality, &pend_scenario, &pend_mes_example, &pend_first_mes }) |f| {
        if (f.len > 0) alloc.free(f.*);
        f.* = &.{};
    }
    pend_active = false;
}

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
    // Demo seeds a chat straight into the store, so Home must hide behind it. bumpMessageLog no longer
    // bumps Home (it fires per stream flush), so the demo transition bumps Home directly.
    regions.bumpHome();
}

fn bootStep() void {
    if (boot_done) return;
    boot_pending -= 1;
    if (boot_pending > 0) return;
    boot_done = true;
    if (boot_demo) return;
    switch (chars_outcome) {
        // Show home by default: home.zig self-loads the recent list on its first render, and its
        // explicit "resume last" action replaces the old silent auto-open (HARD_RULE 4).
        .ok => {},
        // A live view never paints demo fixtures: an unreachable backend shows home, whose recent
        // fetch also fails, so home renders its error state. Fixtures seed ONLY in ?demo (boot above).
        .unreachable_backend => boot_log.warn("backend unreachable - showing home (no demo fixtures in a live view)", .{}),
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
    // clear() nulls selected_index, so without this every refetch (card save, import, duplicate,
    // avatar replace) silently deselected the character app-wide. Duped because clear() frees it.
    const prev_avatar: ?[]u8 = if (char_store.selected()) |c| (alloc.dupe(u8, c.avatar) catch null) else null;
    defer if (prev_avatar) |a| alloc.free(a);

    char_store.global.clear();
    // Store rebuild invalidates any in-flight chat load: its captured index is now stale.
    chat_load_seq +%= 1;
    for (list) |cj| try appendCharacter(cj);
    if (prev_avatar) |want| reselectByAvatar(want);
    recomputeView();
}

/// Re-select the character carrying `avatar` after a rebuild. A character deleted server-side is
/// simply absent, and leaving the store deselected is the honest outcome rather than selecting
/// whoever now sits at the old index.
fn reselectByAvatar(avatar: []const u8) void {
    for (char_store.slice(), 0..) |c, i| {
        if (std.mem.eql(u8, c.avatar, avatar)) {
            char_store.global.select(i);
            return;
        }
    }
    chars_log.debug("rebuild: previously selected avatar is gone, staying deselected", .{});
}

fn appendCharacter(cj: data.CharacterJson) !void {
    // Copies out of the json Parsed arena into the store's allocator (Z97: the Parsed is
    // deinited right after this loop).
    // Through data.jsonStr: these arrive straight from the card's own JSON, so a card from another
    // tool can carry any shape and a wrong one must cost that field, never the whole list.
    const name = try alloc.dupe(u8, data.jsonStr(cj.name));
    errdefer alloc.free(name);
    const avatar = try alloc.dupe(u8, cj.avatar);
    errdefer alloc.free(avatar);
    const desc = try alloc.dupe(u8, data.jsonStr(cj.description));
    errdefer alloc.free(desc);
    const chat = try alloc.dupe(u8, data.jsonStr(cj.chat));
    errdefer alloc.free(chat);
    const first_mes = try alloc.dupe(u8, data.jsonStr(cj.first_mes));
    errdefer alloc.free(first_mes);
    const create_date = try alloc.dupe(u8, data.jsonStr(cj.create_date));
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
    // The connection lives in the same settings blob; mine it here so send knows the backend.
    conn_mod.setFrom(settings_str);
    // The samplers and the instruct/context templates ride the same blob. AFTER conn_mod.setFrom:
    // the samplers are adopted off the freshly mined connection, then localStorage overrides (C-CFG).
    config_state.setFrom(settings_str);
    // World-info global selection + budget ride the same blob (w3-wi).
    wi_actions.setFrom(settings_str);
    // Persona selection by precedence (user_avatar, default_persona, first), and mark the store
    // authoritative so a later save can serialize the persona set (C-PERS).
    persona_actions.applyAutoSelect(settings_str);
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

/// Open the chat for the character at `index` (store order) using the default tail window.
pub fn loadCharacterChat(index: usize) void {
    loadCharacterChatWindow(index, pager.TAIL_LIMIT, false);
}

/// Open the chat for the character at `index` (store order) with an explicit tail-window `limit`.
/// Sequenced by the chat-load ticket; sets aria-busy on #chat for the duration; an error status keeps
/// the current view; the greeting is seeded only on a true 200-empty response. The 409 re-sync passes a
/// limit sized to keep the on-screen window plus the newest tail.
fn loadCharacterChatWindow(index: usize, limit: usize, is_resync: bool) void {
    if (zx.platform.role != .client) return;
    const chars = char_store.slice();
    if (index >= chars.len) {
        chars_log.warn("load chat: no character at index {d} of {d}", .{ index, chars.len });
        return;
    }
    const c = chars[index];
    chars_log.debug("load chat request: index {d} {s}", .{ index, c.name });
    chat_load_seq +%= 1;
    // Mark this load as the re-sync (or clear any pending re-sync intent on a normal open), keyed to the
    // freshly-bumped seq so only this exact completion restores the anchor.
    resync_seq = if (is_resync) chat_load_seq else null;
    const file_name = chatFileName(c) orelse return;
    defer alloc.free(file_name);
    // Paged tail window (invariant 2 + 4): the reader loads the newest slice, not the whole chat,
    // and grows upward from there. Index-anchored, cf_id flag dark.
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = c.avatar,
        .file_name = file_name,
        .paged = true,
        .limit = limit,
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
    // Clear the re-sync marker on the matching seq whether this load is current OR superseded, so a later
    // normal open can never inherit it; a second back-to-back re-sync already overwrote resync_seq.
    const was_resync = resync_seq == seq;
    if (was_resync) resync_seq = null;
    if (seq != chat_load_seq) {
        // A newer load (or a store rebuild) owns the ticket and the aria-busy flag now.
        chars_log.debug("load chat: superseded mid-fetch, abandoning", .{});
        return;
    }
    // This completion is current, so any 409 re-sync it may be servicing is now resolved; clear the
    // guard whether the load below succeeds or keeps the current view on error.
    pager.clearResync();
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
    const page = data.parseChatPage(alloc, parsed.value) catch {
        chars_log.err("chat load failed: out of memory - keeping current chat", .{});
        return;
    };
    defer data.freeChatPage(alloc, page);

    store.global.clear();
    pager.reset();
    char_store.global.select(index);
    // The author's note belongs to THIS chat's header, so it loads with the chat and is replaced
    // wholesale on every open. The full token gates its save (C-CFG).
    // The chat-linked lorebook + link identity live in the same header (w3-wi).
    if (chatFileName(c)) |fname| {
        defer alloc.free(fname);
        an_state.setFromPage(c.avatar, fname, page.chat_metadata, page.full_token);
        wi_actions.setChatContext(c.avatar, fname, page.chat_metadata, page.full_token);
    } else {
        wi_actions.setChatContext("", "", "", "");
    }
    // Deep-load the card's personality/scenario/mesExamples once, so the send prompt is not the
    // degraded shallow form. Reused for every send against this card.
    fetchDeepCard(c.avatar);

    const char_avatar: ?[]u8 = if (c.avatar.len > 0) data.thumbUrl(alloc, "avatar", c.avatar) catch null else null;
    defer if (char_avatar) |u| alloc.free(u);
    const persona = activePersona();
    const persona_avatar: ?[]u8 = if (persona) |p|
        (if (p.avatar.len > 0) data.thumbUrl(alloc, "persona", p.avatar) catch null else null)
    else
        null;
    defer if (persona_avatar) |u| alloc.free(u);

    if (page.messages.len > 0) {
        for (page.messages) |m| {
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
    // window_offset = absolute index of the window's first message. Saturating: total_items vs slice
    // length is an untrusted server relation and must not underflow to a huge usize (silent in ReleaseSmall).
    store.global.markAllHistory();
    store.global.window_offset = page.total_items -| page.messages.len;
    if (chatFileName(c)) |fname| {
        defer alloc.free(fname);
        pager.open(c.avatar, fname, c.name, char_avatar orelse "", persona_avatar orelse "", page.total_items, page.has_more_before, page.change_token);
    }
    // The whole-file token rides alongside the tail token; a message mutation must present it (the tail
    // token 409s by design). Set here on every open/resync so the next mutation carries a current one.
    switch (parsed.value) {
        .object => |root_obj| if (root_obj.get("full_token")) |ft| switch (ft) {
            .string => |s| pager.setFullToken(s),
            else => {},
        },
        else => {},
    }
    regions.bumpMessageLog();
    regions.bumpShell();
    chars_log.info("opened chat: {s} ({d} of {d} messages)", .{ c.name, page.messages.len, page.total_items });
    // The bumps above re-rendered synchronously (S1 probe finding d), so the whole window is in the
    // DOM. A re-sync restores the prior anchor (near-bottom tail-jumps); a normal open lands newest.
    if (was_resync) {
        js.global.call(void, "__st_reader_after_resync", .{}) catch {};
    } else {
        scrollChatToNewest();
    }
}

/// Reloads the currently open chat's tail window. The scroll-up pump calls this (via the
/// __st_reader_resync door export) when a prepend returns 409: the file changed above the window,
/// so history state is dropped and the reader re-syncs to the newest slice.
pub fn reloadCurrentChat() void {
    const idx = char_store.global.selected_index orelse {
        // No open chat: nothing to reload, so release the re-sync guard the caller set.
        pager.clearResync();
        return;
    };
    chars_log.info("reader re-sync: reloading current chat after a stale prepend", .{});
    // Snapshot the scrolled-up anchor from the still-current DOM before the reload seeds a new window,
    // so onChatDone can restore the reader's place; near-bottom captures nothing and tail-jumps.
    js.global.call(void, "__st_reader_capture_anchor", .{}) catch {};
    // Size the tail reload to keep the whole on-screen window plus the newest tail: a centered load
    // would drop the tail, and the reader has no forward-paging pump to get back down.
    const loaded = store.global.slice().len;
    const resync_limit = loaded + pager.BATCH;
    loadCharacterChatWindow(idx, resync_limit, true);
}

fn setChatBusy(busy: bool) void {
    const el = dom_event.elementById(alloc, "chat") orelse return;
    defer el.deinit();
    if (busy) el.setAttribute("aria-busy", "true") else el.removeAttribute("aria-busy");
}

fn scrollChatToNewest() void {
    if (zx.platform.role != .client) return;
    // Scroll the container across a double rAF (glue-owned): content-visibility lays out late rows
    // after the first frame, so a single-frame scrollIntoView on the last message lands short.
    js.global.call(void, "__st_reader_scroll_bottom", .{}) catch return;
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
//
// All three helpers below are `async`, so they hand back a Promise and the return type must name it.
// Asking for `void` made a SUCCESSFUL call return InvalidType, which fired the catch branch (logging
// a missing helper that is right there) and double-freed a jsz slot on the way out. The full
// mechanism is in card_editor.uploadAvatar's header.

/// Export stays a JS helper: a blob download needs objectURL + a.click. Zig hands it the
/// avatar and the display name (the old helper looked both up in the deleted jsCharacters).
pub fn exportCharacter(index: usize) void {
    if (zx.platform.role != .client) return;
    const c = charAt(index) orelse return;
    const ret = js.global.call(?js.Value, "__st_char_export", .{ js.string(c.avatar), js.string(c.name) }) catch {
        chars_log.warn("export helper missing", .{});
        return;
    };
    if (ret) |r| r.deinit();
}

/// Import stays a JS helper: File/FormData cannot cross the wasm boundary.
pub fn importCharacterFile() void {
    if (zx.platform.role != .client) return;
    const ret = js.global.call(?js.Value, "__st_char_import", .{}) catch {
        chars_log.warn("import helper missing", .{});
        return;
    };
    if (ret) |r| r.deinit();
}

/// Avatar replacement stays a JS helper for the same multipart reason.
pub fn replaceAvatarFile(index: usize) void {
    if (zx.platform.role != .client) return;
    const c = charAt(index) orelse return;
    const ret = js.global.call(?js.Value, "__st_char_avatar", .{js.string(c.avatar)}) catch {
        chars_log.warn("avatar helper missing", .{});
        return;
    };
    if (ret) |r| r.deinit();
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

// ---- send loop -----------------------------------------------------------------------------

/// A top-level string field off the deep-card object, or "" when absent or not a string (w3-wi).
fn cardStr(obj: *const std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn fetchDeepCard(avatar: []const u8) void {
    if (zx.platform.role != .client) return;
    if (avatar.len == 0 or deep_in_flight) return;
    if (std.mem.eql(u8, avatar, deep_avatar)) return;
    const body = std.json.Stringify.valueAlloc(alloc, .{ .avatar_url = avatar }, .{}) catch return;
    defer alloc.free(body);
    setOwned(&deep_pending, avatar);
    deep_in_flight = true;
    net.request("/api/characters/get", body, 0, onDeepCardDone, .{});
}

/// Drop the cached deep card and re-fetch it for the selected character. The card editor calls this
/// after a save: fetchDeepCard early-returns while the avatar still matches, so without clearing the
/// key first the send loop would keep prompting from the fields as they were before the edit.
pub fn refreshDeepCard() void {
    if (zx.platform.role != .client) return;
    setOwned(&deep_avatar, "");
    if (char_store.selected()) |c| fetchDeepCard(c.avatar);
}

fn onDeepCardDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    deep_in_flight = false;
    if (res == null or status < 200 or status >= 300) {
        chars_log.warn("deep card fetch failed: {d} - prompt uses the shallow form", .{status});
        return;
    }
    // Raw body once (w3-wi): the prompt strings parse locally; the SAME bytes go to the store's
    // one card-adoption entry point (adoptCharCard), which owns the book memory (probe 3 delta).
    const body = res.?.text() catch {
        chars_log.warn("deep card body unreadable - prompt uses the shallow form", .{});
        return;
    };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch {
        chars_log.warn("deep card body unparseable - prompt uses the shallow form", .{});
        return;
    };
    if (parsed != .object) {
        chars_log.warn("deep card body is not an object - prompt uses the shallow form", .{});
        return;
    }
    const obj = &parsed.object;
    setOwned(&deep_avatar, deep_pending);
    setOwned(&deep_personality, cardStr(obj, "personality"));
    setOwned(&deep_scenario, cardStr(obj, "scenario"));
    setOwned(&deep_mes_example, cardStr(obj, "mes_example"));
    wi_actions.adoptCard(body);
    chars_log.debug("deep card loaded: personality {d}b scenario {d}b examples {d}b", .{ deep_personality.len, deep_scenario.len, deep_mes_example.len });
}

fn deepField(c: char_store.Character, shallow: []const u8, deep: []const u8) []const u8 {
    if (deep_avatar.len > 0 and std.mem.eql(u8, deep_avatar, c.avatar)) return deep;
    return shallow;
}

/// Send the composer's text: append the user turn to the display, persist it, then fetch a budgeted
/// prompt window from the spine (NOT the display store) and open the streaming generate through the JS
/// pump (ZX16). The prompt window is a separate `/api/chats/get` fetch so a tail-only display never
/// bounds what the model sees (invariant 2); onPromptWindowDone assembles + dispatches once it lands.
pub fn sendMessage() void {
    if (zx.platform.role != .client) return;
    const conn = conn_mod.active() orelse {
        net_log.warn("send: no backend configured (textgen only this phase)", .{});
        return;
    };
    if (conn.api_server.len == 0) {
        net_log.warn("send: backend has no server URL", .{});
        return;
    }
    const c = char_store.selected() orelse {
        net_log.warn("send: no character selected", .{});
        return;
    };
    // A prior send is still assembling its prompt window; drop this one rather than race two builds
    // through the single pending slot. The window is one fetch RTT.
    if (pend_active) {
        net_log.warn("send: previous send still assembling its prompt", .{});
        return;
    }
    const text = readComposer() orelse return;
    defer alloc.free(text);
    clearComposer();

    const persona = activePersona();
    const user_name = if (persona) |p| p.name else "You";
    const persona_avatar: ?[]u8 = if (persona) |p|
        (if (p.avatar.len > 0) data.thumbUrl(alloc, "persona", p.avatar) catch null else null)
    else
        null;
    defer if (persona_avatar) |u| alloc.free(u);
    const char_avatar: ?[]u8 = if (c.avatar.len > 0) data.thumbUrl(alloc, "avatar", c.avatar) catch null else null;
    defer if (char_avatar) |u| alloc.free(u);

    store.global.appendCopy(user_name, text, persona_avatar orelse "") catch |err| {
        chars_log.err("send: append user turn failed: {s}", .{@errorName(err)});
        return;
    };
    regions.bumpMessageLog();
    scrollChatToNewest();

    // Capture the append context, then persist the user turn now so a failed generation still keeps
    // it. The assistant turn persists on stream seal (persistNewTurns via the __st_persist_turns hook).
    setOwned(&send_avatar, c.avatar);
    if (chatFileName(c)) |fname| {
        setOwned(&send_file, fname);
        alloc.free(fname);
    }
    send_seq = chat_load_seq;
    appendTurn(user_name, text, true);

    if (!stashSend(conn, c, persona, user_name, text, char_avatar orelse "")) {
        chars_log.err("send: could not stash the send context", .{});
        return;
    }
    // No file yet: degrade to greeting + user turn (a null page) rather than fetch a malformed body.
    if (send_file.len == 0) {
        onPromptWindowDone(0, 0, null);
        return;
    }
    const win_body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = c.avatar,
        .file_name = send_file,
        .paged = true,
        .limit = pager.PROMPT_LIMIT,
    }, .{}) catch {
        freePending();
        return;
    };
    defer alloc.free(win_body);
    net.request("/api/chats/get", win_body, 0, onPromptWindowDone, .{});
}

/// Dupes everything the deferred prompt build needs into pending ownership: the connection, the card
/// ctx fields (deep form when loaded), the persona, the user turn, and the first_mes for greeting
/// reconstruction. False only when the connection URLs cannot be duped (OOM).
fn stashSend(conn: generate.Connection, c: char_store.Character, persona: ?persona_store.Persona, user_name: []const u8, text: []const u8, char_avatar_thumb: []const u8) bool {
    if (!stashConn(conn)) return false;
    if (!stashTemplates(config_state.activeTemplates())) return false;
    if (!stashNote()) return false;
    setOwned(&pend_char_name, c.name);
    setOwned(&pend_char_avatar, char_avatar_thumb);
    setOwned(&pend_user_name, user_name);
    setOwned(&pend_user_text, text);
    setOwned(&pend_persona_desc, if (persona) |p| p.description else "");
    setOwned(&pend_description, c.description);
    setOwned(&pend_personality, deepField(c, c.personality, deep_personality));
    setOwned(&pend_scenario, deepField(c, c.scenario, deep_scenario));
    setOwned(&pend_mes_example, deepField(c, c.mes_example, deep_mes_example));
    setOwned(&pend_first_mes, c.first_mes);
    pend_active = true;
    return true;
}

/// The instruct sequence family a stored turn wraps in. is_system wins over is_user: a narrator line
/// is a system turn whoever is nominally credited with it.
fn roleOf(m: data.ChatMsg) templates.Role {
    if (m.is_system) return .system;
    return if (m.is_user) .user else .assistant;
}

const Anchors = struct { before: []const u8 = "", after: []const u8 = "" };

/// The note text for the story string's two anchor slots. Only the position the note actually names
/// gets it; in_chat notes reach the prompt through the history instead and get neither.
fn noteAnchors(note: authors_note.Note) Anchors {
    if (!note.active()) return .{};
    return switch (note.position) {
        .before_prompt => .{ .before = note.prompt },
        .in_prompt => .{ .after = note.prompt },
        .in_chat => .{},
    };
}

/// Prompt-window fetch completion: parse the spine page (a failure degrades to a null page), then
/// assemble and dispatch the generate. Always frees the pending state.
fn onPromptWindowDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (!pend_active) return;
    defer freePending();
    var page: ?data.ChatPage = null;
    if (res != null and status >= 200 and status < 300) {
        if (res.?.json(std.json.Value)) |parsed| {
            defer parsed.deinit();
            if (data.parseChatPage(alloc, parsed.value)) |p| {
                page = p;
            } else |_| {}
        } else |_| {}
    } else if (res != null) {
        net_log.warn("send: prompt window fetch returned {d} - degrading to the user turn", .{status});
    }
    defer if (page) |p| data.freeChatPage(alloc, p);
    dispatchGenerate(page) catch |err| {
        chars_log.err("send: prompt/body build failed: {s}", .{@errorName(err)});
    };
}

/// Builds the prompt history from the fetched spine window and opens the generate stream. The window
/// is the deep history (may exceed the display); the greeting is reconstructed when the fetch reached
/// the head of the file (it is display-only, never persisted), and the just-sent user turn is appended
/// unless the race already put it at the window tail (dedup). buildPromptBudgeted trims to the char
/// budget, so nothing here is bounded by what is on screen (invariant 2).
fn dispatchGenerate(page: ?data.ChatPage) !void {
    const conn = pend_conn orelse return;
    var history: std.ArrayList(generate.PromptMsg) = .empty;
    defer history.deinit(alloc);

    const at_head = if (page) |p| !p.has_more_before else true;
    const first_is_user = if (page) |p| (p.messages.len > 0 and p.messages[0].is_user) else true;
    var greeting: ?[]u8 = null;
    defer if (greeting) |g| alloc.free(g);
    if (at_head and first_is_user and pend_first_mes.len > 0) {
        greeting = data.renderGreeting(alloc, pend_first_mes, pend_char_name, pend_user_name) catch null;
        if (greeting) |g| try history.append(alloc, .{ .name = pend_char_name, .mes = g });
    }

    var user_turn_present = false;
    if (page) |p| {
        for (p.messages) |m| {
            const name = if (m.name.len > 0) m.name else if (m.is_user) pend_user_name else pend_char_name;
            try history.append(alloc, .{ .name = name, .mes = m.mes, .role = roleOf(m) });
        }
        if (p.messages.len > 0) {
            const last = p.messages[p.messages.len - 1];
            user_turn_present = last.is_user and std.mem.eql(u8, last.mes, pend_user_text);
        }
    }
    if (!user_turn_present) try history.append(alloc, .{ .name = pend_user_name, .mes = pend_user_text, .role = .user });

    // The note's anchor positions render through the story string; the in_chat position is inserted
    // into the history by the builder. Both read the same note, so only one of them ever fires.
    const anchors = noteAnchors(pend_note);
    const ctx = generate.Ctx{
        .char = pend_char_name,
        .user = pend_user_name,
        .persona = pend_persona_desc,
        .description = pend_description,
        .personality = pend_personality,
        .scenario = pend_scenario,
        .mes_example = pend_mes_example,
        .anchor_before = anchors.before,
        .anchor_after = anchors.after,
    };
    const shape = generate.Shape{ .tpl = pend_tpl, .note = pend_note };
    const prompt = try generate.buildPromptBudgeted(alloc, ctx, history.items, generate.promptCharBudget(conn), shape);
    defer alloc.free(prompt);
    var stop_buf: [1][]const u8 = undefined;
    const body = try generate.buildRequestBody(alloc, conn, prompt, generate.stopSequences(pend_tpl.instruct, &stop_buf));
    defer alloc.free(body);

    js.global.call(void, "__st_send_stream", .{
        js.string("/api/backends/text-completions/generate"),
        js.string(pend_char_name),
        js.string(pend_char_avatar),
        js.string(body),
    }) catch {
        net_log.warn("send: __st_send_stream helper missing", .{});
    };
}

/// Called by the JS pump on stream seal (via the __st_persist_turns export): persist the assistant
/// reply. It is the last message, since a single stream runs between send and seal, and this only
/// fires when the stream actually began (startStream rejects before .then otherwise).
pub fn persistNewTurns() void {
    if (zx.platform.role != .client) return;
    if (send_file.len == 0) return;
    // A resync (a 409 append, or the user opening another chat) replaced the store mid-generation, so
    // the last message is no longer this send's reply. Skip rather than append a stale message.
    if (chat_load_seq != send_seq) {
        chars_log.debug("assistant append skipped: chat re-synced mid-generation", .{});
        return;
    }
    const msgs = store.slice();
    if (msgs.len == 0) return;
    const last = msgs[msgs.len - 1];
    appendTurn(last.name, last.body, false);
}

/// Persist one turn to the open chat via the server append route, never a whole-file save, so history
/// above the display window is preserved (invariant 2). The user turn goes on send, the assistant
/// turn on seal. The change token is the reader's, shared for optimistic concurrency.
fn appendTurn(name: []const u8, mes: []const u8, is_user: bool) void {
    if (zx.platform.role != .client) return;
    if (send_file.len == 0 or send_avatar.len == 0) return;
    const send_date: i64 = @intFromFloat(nowMs());
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = send_avatar,
        .file_name = send_file,
        .limit = pager.TAIL_LIMIT,
        .change_token = pager.currentToken(),
        .messages = .{
            .{
                .name = name,
                .is_user = is_user,
                .is_system = false,
                .send_date = send_date,
                .mes = mes,
                .extra = .{},
            },
        },
    }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/chats/append", body, @intFromBool(is_user), onAppendDone, .{});
}

fn onAppendDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    const which: []const u8 = if (tag != 0) "user" else "assistant";
    if (status == 409) {
        // A concurrent whole-file save changed the file under us. Re-sync to the tail via the reader's
        // 409 path; the just-added turn drops from view and the user re-sends. Accepted rare edge: a
        // save landing mid-generation means the streamed reply also needs a re-send to persist.
        chars_log.info("chat append ({s}): file changed (409), re-syncing to the tail", .{which});
        pager.beginResync();
        reloadCurrentChat();
        return;
    }
    if (status < 200 or status >= 300) {
        net_log.warn("chat append ({s}) failed: {d} - turn not persisted", .{ which, status });
        return;
    }
    if (res) |r| {
        if (r.json(struct { ok: ?bool = null, appended: ?i64 = null, change_token: []const u8 = "" })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.change_token.len > 0) pager.adoptToken(parsed.value.change_token);
        } else |_| {}
    }
    chars_log.debug("chat append ({s}) persisted", .{which});
}

/// Abort the in-flight reply and seal what arrived. The JS pump cancels the SSE reader, which runs
/// the stream to its seal (bridge.streamEnd) in the fetch finally.
pub fn stopStream() void {
    if (zx.platform.role != .client) return;
    js.global.call(void, "__st_send_stop", .{}) catch {
        net_log.warn("send: __st_send_stop helper missing", .{});
    };
}

fn readComposer() ?[]u8 {
    if (zx.platform.role != .client) return null;
    const el = dom_event.elementById(alloc, "send_textarea") orelse return null;
    defer el.deinit();
    const raw = el.ref.getAlloc(js.String, alloc, "value") catch return null;
    defer alloc.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return alloc.dupe(u8, trimmed) catch null;
}

fn clearComposer() void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(alloc, "send_textarea") orelse return;
    defer el.deinit();
    el.ref.set("value", js.string("")) catch {};
    const style = el.ref.get(js.Object, "style") catch return;
    defer style.deinit();
    style.set("height", js.string("auto")) catch {};
}
