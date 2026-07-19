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
const tokenizer = @import("./tokenizer.zig");
const templates = @import("./templates.zig");
const authors_note = @import("./authors_note.zig");
const an_state = @import("./authors_note_state.zig");
const config_state = @import("./config_state.zig");
const conn_mod = @import("./connection.zig");
const char_store = @import("./character_store.zig");
const character_view = @import("./character_view.zig");
const tag_store = @import("./tag_store.zig"); // w3-reason 3d tags
const persona_store = @import("./persona_store.zig");
const persona_actions = @import("./persona_actions.zig");
const store = @import("./store.zig");
const wi_actions = @import("./world_info_actions.zig"); // w3-wi
const wi_store = @import("./world_info.zig"); // w3-wi-engine
const wi_timed = @import("./world_info_timed.zig"); // wi-timed: the chat's sticky/cooldown state
const pager = @import("./pager.zig");
const group_send = @import("./group_send.zig"); // w3-grp
const group_store = @import("./group_store.zig"); // w3-chatref
const group_actions = @import("./group_actions.zig"); // w3-chatref: panel bump on deselect
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

// w3-chatref: bit 63 of the chat-load tag marks a group load; the low halves stay index+seq.
const GROUP_TAG_BIT: u64 = 1 << 63;

/// w3-chatref: the group whose chat the display currently shows; null = solo. Set on a group open's
/// completion, cleared by any solo open, read by the reader's 409 re-sync.
var open_group_index: ?usize = null;

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
var deep_system_prompt: []u8 = &.{};
var deep_post_history: []u8 = &.{};
var deep_char_note: []u8 = &.{};
var deep_char_note_depth: i64 = authors_note.default_depth;
var deep_char_note_role: authors_note.Role = .system;
// chunk-4: the card's creator notes, so world-info matchCreatorNotes can scan them.
var deep_creator_notes: []u8 = &.{};
// The card's version + alternate greetings, for {{charVersion}} / {{greeting::N}}; deep-only fields.
var deep_char_version: []u8 = &.{};
var deep_alt_greetings: [][]u8 = &.{};
var deep_in_flight: bool = false;

/// Captured at send so the seal-time assistant append targets the chat the send opened against, even
/// if the selection changed during the seconds-long generation.
var send_avatar: []u8 = &.{};
var send_file: []u8 = &.{};
/// The chat-load ticket at send time. A resync (a 409 append, or the user opening another chat) bumps
/// it mid-generation, so the seal-time assistant append checks it and skips a now-stale target.
var send_seq: u32 = 0;
/// wi-timed: this send touched a live timed window, so the seal persists the state to the chat header.
var pend_timed_persist: bool = false;

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
/// The card's own system_prompt override (deep field), captured at send. Empty = use the global.
var pend_system_prompt: []u8 = &.{};
/// The card's own post_history_instructions (jailbreak) override, captured at send. Empty = global.
var pend_post_history: []u8 = &.{};
/// The card's own depth note (data.extensions.depth_prompt), captured at send.
var pend_char_note: []u8 = &.{};
/// The card's creator notes, captured at send for world-info matchCreatorNotes scanning.
var pend_creator_notes: []u8 = &.{};
/// The card's version + alternate greetings, captured at send for {{charVersion}} / {{greeting::N}}.
var pend_char_version: []u8 = &.{};
var pend_alt_greetings: [][]u8 = &.{};
var pend_char_note_depth: i64 = authors_note.default_depth;
var pend_char_note_role: authors_note.Role = .system;

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
    // The tokenizer resolver reads the settings model first, then the probed one (stock online_status).
    const configured = if (conn.model.len > 0) conn.model else conn_mod.probedModel();
    const m = alloc.dupe(u8, configured) catch {
        alloc.free(t);
        alloc.free(s);
        return false;
    };
    if (pend_conn) |c| generate.freeConnection(alloc, c);
    pend_conn = .{
        .api_type = t,
        .api_server = s,
        .model = m,
        .token_padding = conn.token_padding,
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
    inline for (.{ &pend_char_name, &pend_char_avatar, &pend_user_name, &pend_user_text, &pend_persona_desc, &pend_description, &pend_personality, &pend_scenario, &pend_mes_example, &pend_first_mes, &pend_system_prompt, &pend_post_history, &pend_char_note, &pend_creator_notes, &pend_char_version }) |f| {
        if (f.len > 0) alloc.free(f.*);
        f.* = &.{};
    }
    freeAltGreetings(&pend_alt_greetings);
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
    group_store.on_group_open = &onGroupOpen; // w3-chatref: the reader half the roster hook expects
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
    const tags = try data.tagsAlloc(alloc, cj.tags);
    errdefer data.freeTags(alloc, tags);
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
        .tags = tags,
        .create_date = create_date,
        .date_last_chat = data.metaU64(cj.date_last_chat),
        .chat_size = data.metaU64(cj.chat_size),
        .data_size = data.metaU64(cj.data_size),
        .name_owned = if (name.len > 0) name else null,
        .avatar_owned = if (avatar.len > 0) avatar else null,
        .description_owned = if (desc.len > 0) desc else null,
        .chat_owned = if (chat.len > 0) chat else null,
        .first_mes_owned = if (first_mes.len > 0) first_mes else null,
        .tags_owned = if (tags.len > 0) tags else null,
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
    // w3-reason 3d tags: mine tags + tag_map off the same settings fetch, no second round-trip.
    tag_store.global.mine(settings_str) catch |err| {
        personas_log.warn("tag mine failed: {s}", .{@errorName(err)});
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
pub fn activePersona() ?persona_store.Persona { // w3-grp: pub for group_send's user turn
    if (persona_store.selected()) |p| return p;
    const s = persona_store.slice();
    if (s.len > 0) return s[0];
    return null;
}

// ---- chat load ---------------------------------------------------------------------------

// w3-chatmgr: the manager's switched chat file, keyed to its character's avatar. Sticky until the
// next default open so send/append/resync all address the switched file, never the card default.
var chat_file_override: []u8 = &.{};
var override_avatar: []u8 = &.{};

/// Open the chat for the character at `index` (store order) using the default tail window.
pub fn loadCharacterChat(index: usize) void {
    leaveGroupMode(); // w3-chatref
    clearChatFileOverride();
    loadCharacterChatWindow(index, pager.TAIL_LIMIT, false);
}

/// w3-chatmgr: open a chosen chat file of the character at `index` (the manager's switch). Every
/// later path that derives the file name (send capture, resync, pager identity) follows the override
/// via chatFileName until a default open clears it.
pub fn loadChatByName(index: usize, file_name: []const u8) void {
    const chars = char_store.slice();
    if (index >= chars.len or file_name.len == 0) return;
    leaveGroupMode(); // w3-chatref
    setOwned(&chat_file_override, file_name);
    setOwned(&override_avatar, chars[index].avatar);
    loadCharacterChatWindow(index, pager.TAIL_LIMIT, false);
}

// w3-chatref: a solo open ends group mode, so the composer routes solo again and the roster row
// unhighlights. Also the group-load failure fallback: the view kept the solo chat, state follows it.
fn leaveGroupMode() void {
    if (group_store.selectedIndex() == null and open_group_index == null) return;
    group_store.deselect();
    open_group_index = null;
    group_actions.bumpPanel();
}

/// w3-chatmgr: the switched file's stem, empty when the card default is active.
pub fn activeChatFile() []const u8 {
    return chat_file_override;
}

fn clearChatFileOverride() void {
    if (chat_file_override.len > 0) alloc.free(chat_file_override);
    chat_file_override = &.{};
    if (override_avatar.len > 0) alloc.free(override_avatar);
    override_avatar = &.{};
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
    const ref = data.ChatRef{ .solo = .{ .avatar = c.avatar, .file = file_name } }; // w3-chatref
    const body = data.pageBody(alloc, ref, .{ .limit = limit }) catch return;
    defer alloc.free(body);
    // Busy only once the request actually dispatches, so an alloc-failure return above
    // cannot leave #chat stuck aria-busy.
    setChatBusy(true);
    // The tag carries both the ticket and the index, so the completion knows exactly which
    // request it answers even with two loads in flight.
    const tag: u64 = (@as(u64, index) << 32) | chat_load_seq;
    net.request(ref.url(), body, tag, onChatDone, .{});
}

/// w3-chatref: open the group at `index` (group_store order) with an explicit tail-window `limit`,
/// through the same ticket/busy/completion mechanics as a solo open (invariant 5: one reader path).
fn openGroupChatWindow(index: usize, limit: usize, is_resync: bool) void {
    if (zx.platform.role != .client) return;
    const groups = group_store.slice();
    if (index >= groups.len) {
        chars_log.warn("load group chat: no group at index {d} of {d}", .{ index, groups.len });
        return;
    }
    const g = groups[index];
    const cid = group_store.chatFileId(&g);
    if (cid.len == 0) return;
    chars_log.debug("load group chat request: index {d} {s}", .{ index, g.name });
    clearChatFileOverride();
    chat_load_seq +%= 1;
    resync_seq = if (is_resync) chat_load_seq else null;
    const ref = data.ChatRef{ .group = .{ .id = cid } };
    const body = data.pageBody(alloc, ref, .{ .limit = limit }) catch return;
    defer alloc.free(body);
    setChatBusy(true);
    const tag: u64 = GROUP_TAG_BIT | (@as(u64, index) << 32) | chat_load_seq;
    net.request(ref.url(), body, tag, onChatDone, .{});
}

// w3-chatref: roster row activation (group_store.on_group_open) opens the group's chat.
fn onGroupOpen(index: usize) void {
    openGroupChatWindow(index, pager.TAIL_LIMIT, false);
}

fn chatFileName(c: char_store.Character) ?[]u8 {
    // w3-chatmgr: a manager-chosen file overrides the card default, for its own character only.
    if (chat_file_override.len > 0 and std.mem.eql(u8, override_avatar, c.avatar)) {
        return alloc.dupe(u8, chat_file_override) catch null;
    }
    if (c.chat.len > 0) return alloc.dupe(u8, c.chat) catch null;
    // Old-glue fallback: "<name> - <today>" with today's UTC date from Date.now via jsz.
    var buf: [10]u8 = undefined;
    const iso = data.isoDateFromMs(nowMs(), &buf);
    return std.fmt.allocPrint(alloc, "{s} - {s}", .{ c.name, iso }) catch null;
}

/// Stock getCharaFilename (utils.js:1351): the avatar filename with its final extension stripped, so
/// it matches what world-info characterFilter.names stores. Regex /\.[^/.]+$/ = drop the last dot and
/// the non-dot, non-slash run after it.
fn charaFilename(avatar: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, avatar, '.') orelse return avatar;
    if (std.mem.indexOfScalarPos(u8, avatar, dot, '/') != null) return avatar;
    return avatar[0..dot];
}

pub fn nowMs() f64 { // w3-grp: pub for group_send's append timestamps
    if (zx.platform.role != .client) return 0;
    const date_ctor = js.global.get(js.Object, "Date") catch return 0;
    defer date_ctor.deinit();
    return date_ctor.call(f64, "now", .{}) catch 0;
}

fn onChatDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    const is_group = (tag & GROUP_TAG_BIT) != 0; // w3-chatref
    const seq: u32 = @truncate(tag);
    const index: usize = @intCast((tag >> 32) & 0x7fff_ffff);
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
    // w3-chatref: resolve the display identity per ref kind; everything below that names a card
    // branches on `char`, the shared reader mechanics run once for both (invariant 5).
    var char: ?char_store.Character = null;
    var group: ?group_store.Group = null;
    if (is_group) {
        const groups = group_store.slice();
        if (index >= groups.len) {
            chars_log.warn("load group chat: group index {d} vanished", .{index});
            return;
        }
        group = groups[index];
    } else {
        const chars = char_store.slice();
        if (index >= chars.len) {
            chars_log.warn("load chat: character index {d} vanished", .{index});
            return;
        }
        char = chars[index];
    }
    if (res == null or status == 0) {
        chars_log.err("chat load failed: network error", .{});
        // w3-chatref: a failed GROUP open keeps the solo view, so group mode must not stick (the
        // composer would silently target the group file behind a solo-looking chat).
        if (is_group) leaveGroupMode();
        return;
    }
    // Server contract: 200 [] / 200 {} = no chat yet (seed the greeting below); any error
    // status = the chat may exist but could not be read - keep the current view.
    if (status < 200 or status >= 300) {
        chars_log.err("chat fetch failed: {d} - keeping current chat", .{status});
        if (is_group) leaveGroupMode(); // w3-chatref
        return;
    }
    const parsed = res.?.json(std.json.Value) catch {
        chars_log.err("chat load failed: malformed body - keeping current chat", .{});
        if (is_group) leaveGroupMode(); // w3-chatref
        return;
    };
    defer parsed.deinit();
    const page = data.parseChatPage(alloc, parsed.value) catch {
        chars_log.err("chat load failed: out of memory - keeping current chat", .{});
        if (is_group) leaveGroupMode(); // w3-chatref
        return;
    };
    defer data.freeChatPage(alloc, page);

    store.global.clear();
    // w3-reason: absolute indices repeat across chats, so open reasoning blocks must not carry over.
    store.reasoning.clearAll();
    pager.reset();
    if (char) |c| {
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
        open_group_index = null; // w3-chatref
    } else {
        // wi-polish: a group chat's note + chat-linked book live in the group chat file's header
        // (the migrated stock home); same load path as solo, keyed by the group chat id (invariant 5).
        const gid = group_store.chatFileId(&group.?);
        an_state.setFromGroupPage(gid, page.chat_metadata);
        wi_actions.setGroupChatContext(gid, page.chat_metadata);
        open_group_index = index;
    }
    // wi-timed: the chat's sticky/cooldown windows load with its header, replaced wholesale on every
    // open (empty metadata clears). Both the solo and group headers carry it under timedWorldInfo.
    wi_timed.setFromMetadata(page.chat_metadata);

    const char_avatar: ?[]u8 = if (char) |c|
        (if (c.avatar.len > 0) data.thumbUrl(alloc, "avatar", c.avatar) catch null else null)
    else
        null;
    defer if (char_avatar) |u| alloc.free(u);
    const persona = activePersona();
    const persona_avatar: ?[]u8 = if (persona) |p|
        (if (p.avatar.len > 0) data.thumbUrl(alloc, "persona", p.avatar) catch null else null)
    else
        null;
    defer if (persona_avatar) |u| alloc.free(u);

    // w3-chatref: group thumbs live only until appendCopyFull copies them into the store.
    var member_thumbs: std.ArrayList([]u8) = .empty;
    defer {
        for (member_thumbs.items) |t| alloc.free(t);
        member_thumbs.deinit(alloc);
    }
    if (page.messages.len > 0) {
        for (page.messages) |m| {
            const fallback = if (char) |c| c.name else ""; // w3-chatref
            const sender = if (m.name.len > 0) m.name else if (m.is_user) "You" else fallback;
            const avatar = if (m.is_user)
                (persona_avatar orelse "")
            else if (char != null)
                (char_avatar orelse "")
            else
                (groupMemberThumb(m.name, &member_thumbs) orelse ""); // w3-chatref
            store.global.appendCopyFull(sender, m.mes, avatar, m.reasoning) catch |err| {
                chars_log.err("append message: {s}, message dropped", .{@errorName(err)});
            };
        }
    } else if (char) |c| {
        if (c.first_mes.len > 0) {
            const user_name = if (persona) |p| p.name else "You";
            const persona_desc = if (persona) |p| p.description else "";
            if (data.renderGreeting(alloc, c.first_mes, .{ .char = c.name, .user = user_name, .persona = persona_desc, .chat_id = c.chat })) |greeting| {
                defer alloc.free(greeting);
                store.global.appendCopy(c.name, greeting, char_avatar orelse "") catch |err| {
                    chars_log.err("append greeting: {s}", .{@errorName(err)});
                };
                chars_log.debug("seeded greeting for {s}", .{c.name});
            } else |err| {
                chars_log.err("greeting render failed: {s}", .{@errorName(err)});
            }
        }
    }
    // window_offset = absolute index of the window's first message. Saturating: total_items vs slice
    // length is an untrusted server relation and must not underflow to a huge usize (silent in ReleaseSmall).
    store.global.markAllHistory();
    store.global.window_offset = page.total_items -| page.messages.len;
    if (char) |c| {
        if (chatFileName(c)) |fname| {
            defer alloc.free(fname);
            pager.open(.{ .solo = .{ .avatar = c.avatar, .file = fname } }, c.name, char_avatar orelse "", persona_avatar orelse "", page.total_items, page.has_more_before, page.change_token);
        }
    } else if (group) |g| { // w3-chatref: the reader pages the group file by the same mechanics
        pager.open(.{ .group = .{ .id = group_store.chatFileId(&g) } }, g.name, "", persona_avatar orelse "", page.total_items, page.has_more_before, page.change_token);
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
    const opened_name = if (char) |c| c.name else group.?.name; // w3-chatref
    chars_log.info("opened chat: {s} ({d} of {d} messages)", .{ opened_name, page.messages.len, page.total_items });
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
    // w3-chatref: a group chat re-syncs through its own window loader, same anchor mechanics.
    if (open_group_index) |gidx| {
        chars_log.info("reader re-sync: reloading current group chat after a stale prepend", .{});
        js.global.call(void, "__st_reader_capture_anchor", .{}) catch {};
        openGroupChatWindow(gidx, store.global.slice().len + pager.BATCH, true);
        return;
    }
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

// w3-chatref: a group row is attributed by its message name (former members still resolve; the
// lookup spans the whole character store). The owned thumb parks on `thumbs` until the store copy.
fn groupMemberThumb(name: []const u8, thumbs: *std.ArrayList([]u8)) ?[]const u8 {
    const ci = group_store.characterIndexByName(name) orelse return null;
    const c = char_store.slice()[ci];
    if (c.avatar.len == 0) return null;
    const t = data.thumbUrl(alloc, "avatar", c.avatar) catch return null;
    thumbs.append(alloc, t) catch {
        alloc.free(t);
        return null;
    };
    return t;
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

/// A string from the card's `data.*` object (the v2 home for system_prompt / post_history_instructions,
/// never mirrored top-level), with a top-level fallback.
fn cardDataStr(obj: *const std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get("data")) |d| {
        if (d == .object) {
            if (d.object.get(key)) |v| {
                if (v == .string) return v.string;
            }
        }
    }
    return cardStr(obj, key);
}

const DepthPromptCard = struct { prompt: []const u8, depth: i64, role: authors_note.Role };

/// The card's depth note from `data.extensions.depth_prompt` (stock character-specific A/N). Prompt
/// borrowed from the parse; depth/role default to 4/system when absent or odd-shaped.
fn cardDepthPrompt(obj: *const std.json.ObjectMap) DepthPromptCard {
    var out = DepthPromptCard{ .prompt = "", .depth = authors_note.default_depth, .role = .system };
    const card_data = obj.get("data") orelse return out;
    if (card_data != .object) return out;
    const ext = card_data.object.get("extensions") orelse return out;
    if (ext != .object) return out;
    const dp = ext.object.get("depth_prompt") orelse return out;
    if (dp != .object) return out;
    const o = dp.object;
    if (o.get("prompt")) |v| {
        if (v == .string) out.prompt = v.string;
    }
    if (o.get("depth")) |v| out.depth = switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch authors_note.default_depth,
        else => authors_note.default_depth,
    };
    if (o.get("role")) |v| out.role = switch (v) {
        .integer => |i| authors_note.Role.fromInt(i) orelse .system,
        .string => |s| roleFromName(s),
        else => .system,
    };
    return out;
}

fn roleFromName(s: []const u8) authors_note.Role {
    if (std.ascii.eqlIgnoreCase(s, "user")) return .user;
    if (std.ascii.eqlIgnoreCase(s, "assistant")) return .assistant;
    return .system;
}

fn freeAltGreetings(list: *[][]u8) void {
    for (list.*) |s| alloc.free(s);
    if (list.*.len > 0) alloc.free(list.*);
    list.* = &.{};
}

/// Dupes `src` into `dst`, replacing its prior contents. On any OOM `dst` ends empty rather than partial.
fn dupeGreetings(dst: *[][]u8, src: []const []const u8) void {
    freeAltGreetings(dst);
    if (src.len == 0) return;
    const list = alloc.alloc([]u8, src.len) catch return;
    var n: usize = 0;
    for (src) |s| {
        list[n] = alloc.dupe(u8, s) catch {
            for (list[0..n]) |g| alloc.free(g);
            alloc.free(list);
            return;
        };
        n += 1;
    }
    dst.* = list;
}

/// Loads `data.alternate_greetings` (array of strings) into deep_alt_greetings, counting strings first
/// so the owned slice is exactly sized (free needs the real length). Non-string entries are skipped.
fn setDeepAltGreetings(obj: *const std.json.ObjectMap) void {
    freeAltGreetings(&deep_alt_greetings);
    const card_data = obj.get("data") orelse return;
    if (card_data != .object) return;
    const ag = card_data.object.get("alternate_greetings") orelse return;
    if (ag != .array) return;
    const items = ag.array.items;
    var count: usize = 0;
    for (items) |item| {
        if (item == .string) count += 1;
    }
    if (count == 0) return;
    const list = alloc.alloc([]u8, count) catch return;
    var n: usize = 0;
    for (items) |item| {
        if (item != .string) continue;
        list[n] = alloc.dupe(u8, item.string) catch {
            for (list[0..n]) |g| alloc.free(g);
            alloc.free(list);
            return;
        };
        n += 1;
    }
    deep_alt_greetings = list;
}

fn fetchDeepCard(avatar: []const u8) void {
    _ = requestDeepCard(avatar);
}

// w3-grp: the group rotation launches a member only after its deep card settles, so the fetch
// reports whether a completion (and the settle hook) will fire at all.
pub const DeepReq = enum { pending, unavailable };

/// Request the deep card for `avatar`. `.pending` = a fetch is in flight (this one, or another
/// whose completion will still fire the settle hook); `.unavailable` = nothing will fire, the
/// caller proceeds with whatever depth the cache has.
pub fn requestDeepCard(avatar: []const u8) DeepReq {
    if (zx.platform.role != .client) return .unavailable;
    if (avatar.len == 0) return .unavailable;
    if (std.mem.eql(u8, avatar, deep_avatar)) return .unavailable;
    if (deep_in_flight) return .pending;
    const body = std.json.Stringify.valueAlloc(alloc, .{ .avatar_url = avatar }, .{}) catch return .unavailable;
    defer alloc.free(body);
    setOwned(&deep_pending, avatar);
    deep_in_flight = true;
    net.request("/api/characters/get", body, 0, onDeepCardDone, .{});
    return .pending;
}

// w3-grp
pub fn deepCardReady(avatar: []const u8) bool {
    return avatar.len > 0 and std.mem.eql(u8, deep_avatar, avatar);
}

// w3-grp
pub fn chatLoadSeq() u32 {
    return chat_load_seq;
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
    // w3-grp: fires on success AND failure so a parked member launch can never hang.
    defer group_send.onDeepCardSettled();
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
    setOwned(&deep_system_prompt, cardDataStr(obj, "system_prompt"));
    setOwned(&deep_post_history, cardDataStr(obj, "post_history_instructions"));
    const dp = cardDepthPrompt(obj);
    setOwned(&deep_char_note, dp.prompt);
    deep_char_note_depth = dp.depth;
    deep_char_note_role = dp.role;
    setOwned(&deep_creator_notes, cardDataStr(obj, "creator_notes"));
    setOwned(&deep_char_version, cardDataStr(obj, "character_version"));
    setDeepAltGreetings(obj);
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
    // w3-chatref: an open group routes the composer into the rotation; the solo path below is
    // untouched when no group is active.
    if (group_store.activeGroupId() != null) {
        sendGroupMessage();
        return;
    }
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
    appendTurn(user_name, text, true, "");

    if (!stashSend(conn, c, persona, user_name, text, char_avatar orelse "")) {
        chars_log.err("send: could not stash the send context", .{});
        return;
    }
    // No file yet: degrade to greeting + user turn (a null page) rather than fetch a malformed body.
    if (send_file.len == 0) {
        onPromptWindowDone(0, 0, null);
        return;
    }
    const ref = data.ChatRef{ .solo = .{ .avatar = c.avatar, .file = send_file } }; // w3-chatref: one page-body path
    const win_body = data.pageBody(alloc, ref, .{ .limit = pager.PROMPT_LIMIT }) catch {
        freePending();
        return;
    };
    defer alloc.free(win_body);
    net.request(ref.url(), win_body, 0, onPromptWindowDone, .{});
}

/// w3-chatref: the composer's group branch. Builds the rotation definition from the open group and
/// hands it to group_send.beginSend; display append, persistence and member launches all ride the
/// 3c-B driver. The user turn persists even with no backend configured (stock parity); each member
/// launch checks the connection itself.
fn sendGroupMessage() void {
    const g = group_store.selected() orelse return;
    if (group_send.isActive()) {
        net_log.warn("group send: a rotation is already running", .{});
        return;
    }
    if (pend_active) {
        net_log.warn("group send: previous send still assembling its prompt", .{});
        return;
    }
    const text = readComposer() orelse return;
    defer alloc.free(text);
    const members = group_store.sendRoster(alloc, &g, char_store.slice()) catch {
        chars_log.err("group send: could not build the roster", .{});
        return;
    };
    defer alloc.free(members);
    const ok = group_send.beginSend(.{
        .chat_id = group_store.chatFileId(&g),
        .strategy = @enumFromInt(@intFromEnum(g.activation_strategy)),
        .allow_self_responses = g.allow_self_responses,
        .members = members,
    }, text, null);
    if (ok) clearComposer();
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
    setOwned(&pend_system_prompt, deepField(c, "", deep_system_prompt));
    setOwned(&pend_post_history, deepField(c, "", deep_post_history));
    setOwned(&pend_char_note, deepField(c, "", deep_char_note));
    setOwned(&pend_creator_notes, deepField(c, "", deep_creator_notes));
    const deep_match = deep_avatar.len > 0 and std.mem.eql(u8, deep_avatar, c.avatar);
    setOwned(&pend_char_version, if (deep_match) deep_char_version else "");
    dupeGreetings(&pend_alt_greetings, if (deep_match) deep_alt_greetings else &.{});
    pend_char_note_depth = if (deep_match) deep_char_note_depth else authors_note.default_depth;
    pend_char_note_role = if (deep_match) deep_char_note_role else .system;
    pend_active = true;
    return true;
}

// w3-wi-engine: one PRNG for the probability entries, seeded from the clock at first send.
var wi_prng: ?std.Random.DefaultPrng = null;

fn wiRandom() std.Random {
    if (wi_prng == null) wi_prng = std.Random.DefaultPrng.init(@bitCast(nowMs()));
    return wi_prng.?.random();
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

// ---- token counting: each piece counted independently (classic script.js:4890), fetch failure
// degrades to the byte-length char budget so a send never hangs. ----

/// Persists across sends so a steady-state send re-fetches only the turns new since the last one, like
/// the classic tokenCache. Keyed by tokenizer identity (and model for the remote tier).
var tok_cache: tokenizer.TokenCache = .{};

/// Concurrent encode fetches in flight. net.zig has 8 slots; this leaves headroom for other traffic
/// while still overlapping round-trips the way the classic client's async getTokenCountAsync calls do.
const TOK_CONCURRENCY: usize = 4;

/// Bumped per job so a straggler encode-completion from an aborted send (a token-fetch failure ends the
/// job via finishByteFallback while its other fetches stay inflight; net.zig does not cancel them) cannot
/// write into a NEW job's arrays. The epoch rides the fetch tag; a mismatch is ignored wholesale.
var tok_epoch_seq: u64 = 0;

/// Bits reserved for the piece index in the fetch tag; the epoch takes the rest. A job has 1 + injections
/// + history pieces, far under 2^20, so 20 bits is ample.
const TOK_INDEX_BITS: u6 = 20;
const TOK_INDEX_MASK: u64 = (1 << TOK_INDEX_BITS) - 1;

const TokJob = struct {
    active: bool = false,
    epoch: u64 = 0,
    pieces: generate.Pieces = undefined,
    token_budget: usize = 0,
    char_budget: usize = 0,
    kind: tokenizer.Tokenizer = .none,
    disc: u64 = 0,
    encode_path: []const u8 = "",
    remote: bool = false,
    /// The resolved stopping-string set, each element owned so it survives freePending; empty = no
    /// stops. Composed by generate.buildStoppingStrings to match the classic frontend's array.
    stop: [][]u8 = &.{},
    /// CR-stripped copies of every piece (overhead, then injections, then history), the strings the
    /// classic client counts (item.replace(/\r/g,'')). Owned. Parallel to `counts`/`filled`.
    texts: [][]u8 = &.{},
    counts: []usize = &.{},
    filled: []bool = &.{},
    n_inj: usize = 0,
    /// Indices still needing a fetch (kept at full allocation length; `q_len` is the valid count so the
    /// slice is never resliced before free). `q_next` is the next to dispatch, `remaining` the unresolved.
    queue: []usize = &.{},
    q_len: usize = 0,
    q_next: usize = 0,
    remaining: usize = 0,
    inflight: usize = 0,
};
var tok_job: TokJob = .{};

/// Strip every CR, owned. The classic client counts `item.replace(/\r/g,'')`, so the count must be over
/// the CR-free bytes; fitAndAssemble strips the joined prompt to the same end.
fn stripCR(s: []const u8) std.mem.Allocator.Error![]u8 {
    var out = try alloc.alloc(u8, s.len);
    var w: usize = 0;
    for (s) |b| {
        if (b == '\r') continue;
        out[w] = b;
        w += 1;
    }
    if (w != s.len) {
        const shrunk = alloc.realloc(out, w) catch out[0..w];
        return shrunk;
    }
    return out;
}

fn freeTokJob() void {
    // A default job (no send ever launched here) has `pieces` undefined; only free a job that started.
    if (!tok_job.active) {
        tok_job = .{};
        return;
    }
    for (tok_job.stop) |s| alloc.free(s);
    if (tok_job.stop.len > 0) alloc.free(tok_job.stop);
    for (tok_job.texts) |t| alloc.free(t);
    if (tok_job.texts.len > 0) alloc.free(tok_job.texts);
    if (tok_job.counts.len > 0) alloc.free(tok_job.counts);
    if (tok_job.filled.len > 0) alloc.free(tok_job.filled);
    if (tok_job.queue.len > 0) alloc.free(tok_job.queue);
    generate.freePieces(alloc, &tok_job.pieces);
    tok_job = .{};
}

/// The single terminal for a send: releases the token job (pieces + fetch buffers) and the pending
/// send state. Every finish and abort path routes here so nothing leaks across the async gap.
fn endSend() void {
    freeTokJob();
    freePending();
}

/// Opens the generate stream from a finished prompt, then ends the send. Reads the connection and the
/// character identity from the still-live pending state (endSend frees them last).
fn finishSend(prompt: []const u8) void {
    defer endSend();
    const conn = pend_conn orelse return;
    const body = generate.buildRequestBody(alloc, conn, prompt, tok_job.stop) catch {
        net_log.warn("send: request-body build failed", .{});
        return;
    };
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

/// Trim on byte lengths against the char budget: the classic pre-token behavior and the fallback when a
/// tokenizer is unavailable or an encode fetch fails. Builds the prompt and finishes the send.
fn finishByteFallback() void {
    const costs = generate.byteCostTable(alloc, tok_job.pieces) catch {
        chars_log.err("send: fallback cost build failed", .{});
        endSend();
        return;
    };
    defer generate.freeCostTable(alloc, costs);
    const prompt = generate.fitAndAssemble(alloc, tok_job.pieces, costs, tok_job.char_budget) catch {
        chars_log.err("send: fallback prompt build failed", .{});
        endSend();
        return;
    };
    defer alloc.free(prompt);
    finishSend(prompt);
}

/// All token counts are in: split them into the story/injection/history cost table and trim on real
/// tokens against the token budget, then open the stream.
fn finishTokenJob() void {
    const n = tok_job.n_inj;
    const costs = generate.CostTable{
        .overhead = tok_job.counts[0],
        .injections = tok_job.counts[1 .. 1 + n],
        .history = tok_job.counts[1 + n ..],
    };
    const prompt = generate.fitAndAssemble(alloc, tok_job.pieces, costs, tok_job.token_budget) catch {
        chars_log.err("send: token prompt build failed", .{});
        endSend();
        return;
    };
    defer alloc.free(prompt);
    finishSend(prompt);
}

fn tokBody(index: usize) std.mem.Allocator.Error![]u8 {
    const conn = pend_conn.?;
    if (tok_job.remote) {
        return std.json.Stringify.valueAlloc(alloc, .{
            .text = tok_job.texts[index],
            .url = conn.api_server,
            .model = conn.model,
            .api_type = conn.api_type,
        }, .{});
    }
    return std.json.Stringify.valueAlloc(alloc, .{ .text = tok_job.texts[index] }, .{});
}

fn fireNextTokenFetch() void {
    // net.request can complete SYNCHRONOUSLY on slot exhaustion (its on_done fires inline), which routes
    // through onTokenCountDone and can tear the job down mid-loop; re-check `active` before each step.
    while (tok_job.active and tok_job.inflight < TOK_CONCURRENCY and tok_job.q_next < tok_job.q_len) {
        const index = tok_job.queue[tok_job.q_next];
        tok_job.q_next += 1;
        const body = tokBody(index) catch {
            finishByteFallback();
            return;
        };
        tok_job.inflight += 1;
        net.request(tok_job.encode_path, body, (tok_job.epoch << TOK_INDEX_BITS) | @as(u64, index), onTokenCountDone, .{});
        alloc.free(body);
    }
}

fn onTokenCountDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    // A straggler from an aborted send carries that job's epoch; ignore it entirely (no inflight
    // decrement, no array write) so it can never touch a newer job's state.
    if (!tok_job.active or (tag >> TOK_INDEX_BITS) != tok_job.epoch) return;
    tok_job.inflight -|= 1;
    const index: usize = @intCast(tag & TOK_INDEX_MASK);
    var count: ?usize = null;
    if (res != null and status >= 200 and status < 300) {
        if (res.?.json(struct { count: ?i64 = null, @"error": ?bool = null })) |parsed| {
            defer parsed.deinit();
            if ((parsed.value.@"error" orelse false) == false) {
                if (parsed.value.count) |c| if (c >= 0) {
                    count = @intCast(c);
                };
            }
        } else |_| {}
    }
    const c = count orelse {
        net_log.warn("send: token count fetch failed ({d}) - falling back to the char estimate", .{status});
        finishByteFallback();
        return;
    };
    tok_job.counts[index] = c;
    tok_job.filled[index] = true;
    tok_cache.put(alloc, tok_job.texts[index], tok_job.disc, c);
    tok_job.remaining -= 1;
    if (tok_job.remaining == 0) {
        finishTokenJob();
        return;
    }
    fireNextTokenFetch();
}

/// Stashes the assembled pieces and tokenizes each (cache first, then bounded fetches). On a setup OOM
/// it degrades to the byte-cost path rather than dropping the send.
fn startTokenJob(pieces: generate.Pieces, token_budget: usize, char_budget: usize, kind: tokenizer.Tokenizer, disc: u64, encode_path: []const u8, remote: bool, stop: [][]u8) void {
    const n = pieces.injections.len;
    const total = 1 + n + pieces.wrapped_history.len;
    tok_epoch_seq +%= 1;
    tok_job = .{
        .active = true,
        .epoch = tok_epoch_seq,
        .pieces = pieces,
        .token_budget = token_budget,
        .char_budget = char_budget,
        .kind = kind,
        .disc = disc,
        .encode_path = encode_path,
        .remote = remote,
        .stop = stop,
        .n_inj = n,
    };
    // No tokenizer resolved (a non-textgen or unknown backend): trim on the char estimate.
    if (kind == .none) return finishByteFallback();
    tok_job.texts = alloc.alloc([]u8, total) catch return startupFail(0);
    // Track how many texts are filled so a mid-loop OOM frees exactly those.
    var built: usize = 0;
    tok_job.counts = alloc.alloc(usize, total) catch return startupFail(built);
    tok_job.filled = alloc.alloc(bool, total) catch return startupFail(built);
    tok_job.queue = alloc.alloc(usize, total) catch return startupFail(built);
    @memset(tok_job.filled, false);

    while (built < total) : (built += 1) {
        const src = pieceText(pieces, n, built);
        tok_job.texts[built] = stripCR(src) catch return startupFail(built);
    }

    tok_job.remaining = 0;
    tok_job.q_next = 0;
    var q: usize = 0;
    for (0..total) |i| {
        if (tok_cache.get(tok_job.texts[i], disc)) |hit| {
            tok_job.counts[i] = hit;
            tok_job.filled[i] = true;
        } else {
            tok_job.queue[q] = i;
            q += 1;
            tok_job.remaining += 1;
        }
    }
    tok_job.q_len = q;
    if (tok_job.remaining == 0) {
        finishTokenJob();
        return;
    }
    fireNextTokenFetch();
}

/// The source string for job unit `i`: index 0 is the overhead, 1..n the injections, the rest history.
fn pieceText(pieces: generate.Pieces, n: usize, i: usize) []const u8 {
    if (i == 0) return pieces.overhead;
    if (i <= n) return pieces.injections[i - 1].wrapped;
    return pieces.wrapped_history[i - 1 - n];
}

/// A token-job setup allocation failed after `built` texts were stripped: free the partial job and
/// degrade to the byte-cost path so the send still goes out.
fn startupFail(built: usize) void {
    for (0..built) |i| alloc.free(tok_job.texts[i]);
    if (tok_job.texts.len > 0) alloc.free(tok_job.texts);
    if (tok_job.counts.len > 0) alloc.free(tok_job.counts);
    if (tok_job.filled.len > 0) alloc.free(tok_job.filled);
    if (tok_job.queue.len > 0) alloc.free(tok_job.queue);
    tok_job.texts = &.{};
    tok_job.counts = &.{};
    tok_job.filled = &.{};
    tok_job.queue = &.{};
    finishByteFallback();
}

/// Prompt-window fetch completion: parse the spine page (a failure degrades to a null page), then
/// assemble and dispatch the generate. The pending state is freed by the send's terminal (endSend),
/// not here, because the token-count round-trip outlives this callback.
fn onPromptWindowDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (!pend_active) return;
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
    // An error here means the send failed BEFORE the token job launched (nothing async in flight), so the
    // terminal cleanup is ours; a launched job frees itself through endSend when it settles.
    dispatchGenerate(page) catch |err| {
        chars_log.err("send: prompt/body build failed: {s}", .{@errorName(err)});
        endSend();
    };
}

/// Builds the prompt history from the fetched spine window, assembles the prompt pieces, and kicks off
/// the token-count job that trims and opens the stream. The window is the deep history (may exceed the
/// display); the greeting is reconstructed when the fetch reached the head of the file, and the just-sent
/// user turn is appended unless the race already put it at the window tail (dedup). An error is returned
/// only for a pre-job failure, whose cleanup the caller owns; nothing on screen bounds the window (inv 2).
fn dispatchGenerate(page: ?data.ChatPage) !void {
    const conn = pend_conn orelse return error.MissingConnection;
    var history: std.ArrayList(generate.PromptMsg) = .empty;
    defer history.deinit(alloc);

    const at_head = if (page) |p| !p.has_more_before else true;
    // An EMPTY page (fresh chat) needs the greeting too; the old guard required a user message and so
    // dropped it on every new conversation. A leading assistant turn already IS the greeting.
    const head_lacks_greeting = if (page) |p| (p.messages.len == 0 or p.messages[0].is_user) else true;
    var greeting: ?[]u8 = null;
    defer if (greeting) |g| alloc.free(g);
    if (at_head and head_lacks_greeting and pend_first_mes.len > 0) {
        greeting = data.renderGreeting(alloc, pend_first_mes, .{
            .char = pend_char_name,
            .user = pend_user_name,
            .persona = pend_persona_desc,
            .description = pend_description,
            .personality = pend_personality,
            .scenario = pend_scenario,
            .mes_example = pend_mes_example,
            // {{pick}} in the greeting seeds off the chat id (stock getChatIdHash); without it the pick
            // hashes an empty chat id and diverges from the old frontend.
            .chat_id = send_file,
        }) catch null;
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
    // w3-grp: a group member launch stashes no user text (the turn is already in the window).
    if (!user_turn_present and pend_user_text.len > 0) try history.append(alloc, .{ .name = pend_user_name, .mes = pend_user_text, .role = .user });

    // w3-wi-engine: candidates come from the store AT DISPATCH, never the stash (probe#3 delta 3:
    // store-owned book memory; the async gap between send and this callback cannot dangle them).
    const wi_candidates: []const wi_store.Entry = wi_store.global.collectActive(alloc) catch &.{};
    defer alloc.free(wi_candidates);
    const wi_budget_chars = (generate.promptCharBudget(conn) *| @as(usize, @intCast(wi_store.global.budget))) / 100;

    // Persona TOP_AN / BOTTOM_AN attaches in generate.assemblePieces, OUTSIDE the WI an-anchors (stock
    // addPersonaDescriptionExtensionPrompt runs after the WI an-merge, script.js:3183 vs world-info.js:5149).
    const eff_note = pend_note;
    // The note's anchor positions render through the story string; the in_chat position is inserted
    // into the history by the builder. Both read the same note, so only one of them ever fires.
    const anchors = noteAnchors(eff_note);
    // Effective system prompt: the card's own system_prompt wins over the global (generate.effectiveSystem).
    const effective_system = generate.effectiveSystem(pend_tpl.sysprompt_enabled, pend_tpl.prefer_character_prompt, pend_system_prompt, pend_tpl.system_prompt);
    var ctx = generate.Ctx{
        .char = pend_char_name,
        .user = pend_user_name,
        .persona = pend_persona_desc,
        .description = pend_description,
        .personality = pend_personality,
        .scenario = pend_scenario,
        .mes_example = pend_mes_example,
        // Card-field macros ({{charPrompt}}/{{greeting}}/...); charPrompt/charInstruction gate on the
        // prefer_character_* flags exactly like stock getCharacterCardFields (script.js:3384/3388).
        .char_prompt = if (pend_tpl.prefer_character_prompt) pend_system_prompt else "",
        .char_instruction = if (pend_tpl.prefer_character_jailbreak) pend_post_history else "",
        .char_depth_prompt = pend_char_note,
        .creator_notes = pend_creator_notes,
        .first_mes = pend_first_mes,
        .alt_greetings = pend_alt_greetings,
        .char_version = pend_char_version,
        .system = effective_system,
        .original = pend_tpl.system_prompt,
        .anchor_before = anchors.before,
        .anchor_after = anchors.after,
        // {{pick}} seeds off the open chat id (stock getChatIdHash macros.js:262 = main_chat ??
        // getCurrentChatId(); this client tracks only the latter, send_file); {{roll}}/{{random}} draw the PRNG.
        .chat_id = send_file,
        .rng = wiRandom(),
    };
    // {{mesExamples}} formatted value: precomputed here (macros.zig cannot reach the example pipeline).
    const mes_fmt = generate.renderMesExamplesMacro(alloc, pend_mes_example, pend_char_name, pend_user_name, pend_tpl.instruct, pend_tpl.context.example_separator, ctx) catch "";
    defer if (mes_fmt.len > 0) alloc.free(mes_fmt);
    ctx.mes_example_formatted = mes_fmt;
    // Jailbreak / post-history: card override wins over the global (same sysprompt gate). Its
    // {{original}} means the global POST_HISTORY here, so resolve against that before it injects.
    const effective_jb = generate.effectiveSystem(pend_tpl.sysprompt_enabled, pend_tpl.prefer_character_jailbreak, pend_post_history, pend_tpl.sysprompt_post_history);
    var jb_ctx = ctx;
    jb_ctx.original = pend_tpl.sysprompt_post_history;
    const jb_resolved: []const u8 = if (effective_jb.len > 0) try generate.substituteMacros(alloc, effective_jb, jb_ctx) else "";
    defer if (jb_resolved.len > 0) alloc.free(jb_resolved);
    // w3-wi-engine: the engine knobs ride the shape; scan depth + recursion + budget are the
    // store's hydrated classic settings, the rng is this module's seeded PRNG.
    const shape = generate.Shape{
        .tpl = pend_tpl,
        .note = eff_note,
        .char_note = .{ .prompt = pend_char_note, .depth = pend_char_note_depth, .role = pend_char_note_role },
        .jailbreak = jb_resolved,
        .wi_entries = wi_candidates,
        .wi_scan_depth = @intCast(@max(0, wi_store.global.scan_depth)),
        .wi_budget_chars = wi_budget_chars,
        .wi_recursive = wi_store.global.recursive,
        .wi_case_sensitive = wi_store.global.case_sensitive,
        .wi_match_whole_words = wi_store.global.match_whole_words,
        .wi_min_activations = @intCast(@max(0, wi_store.global.min_activations)),
        .wi_min_activations_depth_max = @intCast(@max(0, wi_store.global.min_activations_depth_max)),
        .wi_use_group_scoring = wi_store.global.use_group_scoring,
        .wi_rng = wiRandom(),
        .wi_timed_in = wi_timed.current(),
        // chunk-4: characterFilter identity, generation type, and the extended scan-source texts. The
        // raw avatar (not the thumb URL) matches stock getCharaFilename; null tags = no tag mapping.
        .wi_chara_filename = charaFilename(send_avatar),
        .wi_char_tags = tag_store.global.tagsFor(send_avatar),
        .wi_generation_trigger = "normal",
        .wi_persona_description = pend_persona_desc,
        .wi_character_description = pend_description,
        .wi_character_personality = pend_personality,
        .wi_character_depth_prompt = pend_char_note,
        .wi_scenario = pend_scenario,
        .wi_creator_notes = pend_creator_notes,
        .persona_position = pend_tpl.persona_position,
        .persona_depth = pend_tpl.persona_depth,
        .persona_role = pend_tpl.persona_role,
    };
    // Assemble the prompt into separately-costable pieces. The budget walk waits until each piece has a
    // real token count (or the byte fallback); pieces is owned and outlives this callback in tok_job.
    const had_timed = wi_timed.hasState();
    var pieces = generate.assemblePieces(alloc, ctx, history.items, shape, true) catch |err| {
        chars_log.err("send: prompt assembly failed: {s}", .{@errorName(err)});
        endSend();
        return;
    };
    // wi-timed: advance the in-memory state now so the NEXT send reads this send's outcome before the
    // server persist. Persist when a window is live now or was before (so an expiry still clears it).
    if (pieces.timed_json) |tj| if (tj.len > 0) wi_timed.advance(tj);
    pend_timed_persist = had_timed or wi_timed.hasState();

    // The full stopping-string set the classic frontend sends (names + instruct sequences + custom),
    // owned so it survives to finishSend past freePending. pend_user_name = name1, pend_char_name = name2.
    const stop_owned = generate.buildStoppingStrings(alloc, pend_tpl, ctx, pend_user_name, pend_char_name) catch {
        generate.freePieces(alloc, &pieces);
        endSend();
        return;
    };

    // Resolve the tokenizer the classic client would use, then count each piece. A configured backend
    // with a supported type uses its own remote tokenizer (exact for llama.cpp); else a local model.
    const kind = tokenizer.bestMatch(conn.api_type, conn.model, conn.api_server.len > 0, false);
    const remote = kind == .remote_textgen;
    const encode_path = if (remote) tokenizer.remote_encode_path else tokenizer.localEncodePath(kind);
    const disc = tokenizer.cacheDisc(kind, conn.model);
    startTokenJob(pieces, generate.promptTokenBudget(conn), generate.promptCharBudget(conn), kind, disc, encode_path, remote, stop_owned);
}

/// Called by the JS pump on stream seal (via the __st_persist_turns export): persist the assistant
/// reply. It is the last message, since a single stream runs between send and seal, and this only
/// fires when the stream actually began (startStream rejects before .then otherwise).
pub fn persistNewTurns() void {
    if (zx.platform.role != .client) return;
    // w3-grp: a group rotation owns this seal (member append + advance); solo must not double-append.
    if (group_send.sealCurrent()) return;
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
    appendTurn(last.name, last.body, false, last.reasoning);
}

/// Persist one turn to the open chat via the server append route, never a whole-file save, so history
/// above the display window is preserved (invariant 2). The user turn goes on send, the assistant
/// turn on seal. The change token is the reader's, shared for optimistic concurrency.
fn appendTurn(name: []const u8, mes: []const u8, is_user: bool, reasoning_text: []const u8) void {
    if (zx.platform.role != .client) return;
    if (send_file.len == 0 or send_avatar.len == 0) return;
    const send_date: i64 = @intFromFloat(nowMs());
    // w3-reason: the sealed reply's thinking persists as extra.reasoning (the classic client's key);
    // a user turn carries "" and loads back as no block.
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
                .extra = .{ .reasoning = reasoning_text },
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
    // wi-timed: the assistant seal (tag 0) just settled the token, so persist the timed window now,
    // chained after the append rather than racing it. A user turn (tag != 0) never carries it.
    if (tag == 0 and pend_timed_persist) {
        pend_timed_persist = false;
        persistTimedMetadata();
    }
}

/// Write the chat's live timed-effect state to the header via /api/chats/metadata (the timedWorldInfo
/// key the fork's allowlist accepts). Fire-and-adopt like the note/link writes: a 409 just means the
/// write missed this seal, and the next send re-persists the full in-memory state, so it self-heals.
fn persistTimedMetadata() void {
    if (zx.platform.role != .client) return;
    if (send_file.len == 0 or send_avatar.len == 0) return;
    var body_arena = std.heap.ArenaAllocator.init(alloc);
    defer body_arena.deinit();
    const ba = body_arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    obj.put(ba, "avatar_url", .{ .string = send_avatar }) catch return;
    obj.put(ba, "file_name", .{ .string = send_file }) catch return;
    obj.put(ba, "change_token", .{ .string = pager.currentToken() }) catch return;
    obj.put(ba, "timedWorldInfo", wi_timed.toValue(ba) catch return) catch return;
    const body = std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = obj }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/chats/metadata", body, 0, onTimedMetaDone, .{});
}

fn onTimedMetaDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (status < 200 or status >= 300) {
        chars_log.debug("timed world-info persist skipped ({d}); re-persists next send", .{status});
        return;
    }
    // Adopt the post-write token so the next append/link is not left holding a stale copy.
    if (res) |r| {
        if (r.json(struct { change_token: []const u8 = "" })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.change_token.len > 0) pager.adoptToken(parsed.value.change_token);
        } else |_| {}
    }
}

/// Abort the in-flight reply and seal what arrived. The JS pump cancels the SSE reader, which runs
/// the stream to its seal (bridge.streamEnd) in the fetch finally.
pub fn stopStream() void {
    if (zx.platform.role != .client) return;
    // w3-grp: clear the rotation queue FIRST so the current member's seal launches nobody else.
    group_send.cancel();
    js.global.call(void, "__st_send_stop", .{}) catch {
        net_log.warn("send: __st_send_stop helper missing", .{});
    };
}

// w3-grp ---- group member launch ----

/// Launch one rotation member: stash THIS member's card into the pending-send slot and fetch
/// the GROUP prompt window; onPromptWindowDone/dispatchGenerate then run unchanged, so the
/// member's prompt is budgeted exactly like a solo send (invariant 2) and streams under the
/// member's own name+avatar. False = could not start; the caller aborts the queue.
pub fn launchGroupMember(m: @import("./group_rotation.zig").Member) bool {
    if (zx.platform.role != .client) return false;
    const gid = group_send.chatId() orelse return false;
    const conn = conn_mod.active() orelse {
        net_log.warn("group launch: no backend configured", .{});
        return false;
    };
    if (conn.api_server.len == 0) return false;
    if (pend_active) {
        net_log.warn("group launch: pending slot busy", .{});
        return false;
    }
    const c = charByAvatar(m.avatar) orelse {
        chars_log.warn("group launch: member {s} is not in the character store", .{m.avatar});
        return false;
    };
    const persona = activePersona();
    const user_name = if (persona) |p| p.name else "You";
    const char_avatar: ?[]u8 = if (c.avatar.len > 0) data.thumbUrl(alloc, "avatar", c.avatar) catch null else null;
    defer if (char_avatar) |u| alloc.free(u);
    send_seq = chat_load_seq;
    if (!stashSend(conn, c, persona, user_name, "", char_avatar orelse "")) {
        chars_log.err("group launch: could not stash the member send context", .{});
        return false;
    }
    // No solo greeting reconstruction and no forced user-turn append for a member launch: the
    // group window already carries every persisted turn, including the user's.
    setOwned(&pend_first_mes, "");
    setOwned(&pend_user_text, "");
    const ref = data.ChatRef{ .group = .{ .id = gid } }; // w3-chatref: one page-body path
    const win_body = data.pageBody(alloc, ref, .{ .limit = pager.PROMPT_LIMIT }) catch {
        freePending();
        return false;
    };
    defer alloc.free(win_body);
    net.request(ref.url(), win_body, 0, onPromptWindowDone, .{});
    return true;
}

// w3-grp
fn charByAvatar(avatar: []const u8) ?char_store.Character {
    for (char_store.slice()) |c| {
        if (std.mem.eql(u8, c.avatar, avatar)) return c;
    }
    return null;
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
