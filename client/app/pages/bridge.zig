const std = @import("std");
const builtin = @import("builtin");
const store = @import("./store.zig");
const pager = @import("./pager.zig");
const char_store = @import("./character_store.zig");
const character_view = @import("./character_view.zig");
const persona_store = @import("./persona_store.zig");
const reading_prefs = @import("./reading_prefs.zig");
const appearance = @import("./appearance.zig");
const backgrounds = @import("./backgrounds.zig");
const char_api = @import("./char_api.zig");
const reader = @import("./reader.zig");
const group_send = @import("./group_send.zig"); // w3-grp
const uploads = @import("./uploads.zig"); // C4: the File->bytes callback lands here
const ui = @import("./ui.zig");
const proto_flags = @import("./proto_flags.zig");
const pointer_track = @import("./pointer_track.zig");
const zx = @import("zx");
const regions = @import("./regions.zig");
const reveal = @import("./reveal.zig");
const instrument = @import("./instrument.zig");
const telemetry = @import("./telemetry.zig"); // C5: uncaught-error + click diagnostics log here
const stream_drive = @import("./stream_drive.zig"); // C2: Zig-owned SSE lifecycle + door pump driver
const notifications = @import("./notifications.zig");
const connection = @import("./connection.zig");
const server_events = @import("./server_events.zig");
const net = @import("./net.zig");
const config_state = @import("./config_state.zig");
const wi_actions = @import("./world_info_actions.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

const chars_log = std.log.scoped(.chars);
const personas_log = std.log.scoped(.personas);
const stream_log = std.log.scoped(.stream);

fn doorBuf(addr: usize, len: usize) []u8 {
    if (addr == 0 or len == 0) return &.{};
    return @as([*]u8, @ptrFromInt(addr))[0..len];
}

fn appendMessage(name_ptr: usize, name_len: usize, body_ptr: usize, body_len: usize, avatar_ptr: usize, avatar_len: usize) callconv(.c) void {
    const name = doorBuf(name_ptr, name_len);
    const body = doorBuf(body_ptr, body_len);
    const avatar = doorBuf(avatar_ptr, avatar_len);
    store.global.append(name, body, avatar) catch |err| {
        store.global.allocator.free(name);
        store.global.allocator.free(body);
        store.global.allocator.free(avatar);
        stream_log.err("append_message: {s}, message dropped", .{@errorName(err)});
        return;
    };
    regions.bumpMessageLog();
}

fn clearMessages() callconv(.c) void {
    store.global.clear();
    pager.reset();
    regions.bumpMessageLog();
}

fn addCharacter(
    name_ptr: usize,
    name_len: usize,
    avatar_ptr: usize,
    avatar_len: usize,
    desc_ptr: usize,
    desc_len: usize,
    chat_ptr: usize,
    chat_len: usize,
    first_mes_ptr: usize,
    first_mes_len: usize,
    fav: u32,
) callconv(.c) void {
    const name = doorBuf(name_ptr, name_len);
    const avatar = doorBuf(avatar_ptr, avatar_len);
    const desc = doorBuf(desc_ptr, desc_len);
    const chat = doorBuf(chat_ptr, chat_len);
    const first_mes = doorBuf(first_mes_ptr, first_mes_len);

    const c = char_store.Character{
        .name = name,
        .avatar = avatar,
        .description = desc,
        .chat = chat,
        .first_mes = first_mes,
        .personality = "",
        .scenario = "",
        .mes_example = "",
        .fav = fav != 0,
        .tags = &.{},
        .name_owned = if (name.len > 0) name else null,
        .avatar_owned = if (avatar.len > 0) avatar else null,
        .description_owned = if (desc.len > 0) desc else null,
        .chat_owned = if (chat.len > 0) chat else null,
        .first_mes_owned = if (first_mes.len > 0) first_mes else null,
    };
    char_store.global.append(c) catch |err| {
        chars_log.err("add_character: {s}, character dropped", .{@errorName(err)});
        regions.bumpShell();
        return;
    };
    character_view.global.compute(char_store.global.slice()) catch |err| {
        chars_log.err("add_character: compute {s}", .{@errorName(err)});
    };
    regions.bumpShell();
}

fn clearCharacters() callconv(.c) void {
    char_store.global.clear();
    character_view.global.compute(&.{}) catch |err| {
        chars_log.err("clear_characters: compute {s}", .{@errorName(err)});
    };
    regions.bumpShell();
}

fn setCharacterMeta(
    index: u32,
    create_date_ptr: usize,
    create_date_len: usize,
    date_last_chat: u64,
    chat_size: u64,
    data_size: u64,
) callconv(.c) void {
    const create_date = doorBuf(create_date_ptr, create_date_len);
    char_store.global.setMeta(index, create_date, date_last_chat, chat_size, data_size);
    character_view.global.compute(char_store.global.slice()) catch |err| {
        chars_log.err("set_character_meta: compute {s}", .{@errorName(err)});
    };
    regions.bumpShell();
}

fn selectCharacter(index: u32) callconv(.c) void {
    char_store.global.select(@intCast(index));
    regions.bumpShell();
}

fn addPersona(
    name_ptr: usize,
    name_len: usize,
    avatar_ptr: usize,
    avatar_len: usize,
    desc_ptr: usize,
    desc_len: usize,
) callconv(.c) void {
    const name = doorBuf(name_ptr, name_len);
    const avatar = doorBuf(avatar_ptr, avatar_len);
    const desc = doorBuf(desc_ptr, desc_len);

    const p = persona_store.Persona{
        .name = name,
        .avatar = avatar,
        .description = desc,
        .name_owned = if (name.len > 0) name else null,
        .avatar_owned = if (avatar.len > 0) avatar else null,
        .description_owned = if (desc.len > 0) desc else null,
    };
    persona_store.global.append(p) catch |err| {
        personas_log.err("add_persona: {s}, persona dropped", .{@errorName(err)});
    };
    regions.bumpShell();
}

fn clearPersonas() callconv(.c) void {
    persona_store.global.clear();
    regions.bumpShell();
}

fn selectPersona(index: u32) callconv(.c) void {
    persona_store.global.select(@intCast(index));
    regions.bumpShell();
}

fn bootInit() callconv(.c) void {
    // The prefetch pump's 409 re-sync reaches char_api through a pointer (reader cannot import
    // char_api without a cycle); wire it before any chat can open.
    reader.resyncFn = char_api.reloadCurrentChat;
    regions.bumpMessageLog();
    // PROTOTYPE: the ?showtabs / ?sysopen / ?openleft / ?openright screenshot flags, read before the
    // first paint so a still frame can show a state that a click would otherwise have to open.
    proto_flags.boot();
    ui.setMotion(ui.storedMotion());
    // Persisted reading prefs land on #chat-root before the first paint of the chat.
    reading_prefs.applyAll();
    reading_prefs.syncAria();
    // Persisted chrome theme overrides and custom CSS land on the document root before first paint.
    appearance.applyAll();
    backgrounds.applyAll();
    // Zig owns boot data orchestration (Z-BOOT): ?demo fixtures, characters + personas,
    // auto-open. The glue only calls __st_boot_init.
    char_api.boot();
    // Past the first paint, stagger the messages in (double-rAF adds hydrated/revealing on #chat-root).
    reveal.startReveal();
    // P3-A: open the live channel. EventSource is the glue's to hold; everything it receives crosses
    // straight back here through __st_server_event. Routes first: the hello arrives on the open.
    wireLiveRoutes();
    if (zx.platform.role == .client) zx.client.js.global.call(void, "__st_events_open", .{}) catch {};
}

/// C4: JS (__st_read_file) hands back the picked file's bytes, name and mime. All three buffers were
/// allocated by the door; uploads.zig owns and frees them, then builds the multipart and posts it.
fn fileReady(
    tag: usize,
    bytes_ptr: usize,
    bytes_len: usize,
    name_ptr: usize,
    name_len: usize,
    mime_ptr: usize,
    mime_len: usize,
) callconv(.c) void {
    uploads.fileReady(
        tag,
        doorBuf(bytes_ptr, bytes_len),
        doorBuf(name_ptr, name_len),
        doorBuf(mime_ptr, mime_len),
    );
}

// Demo fixtures are opt-in (glue calls this on ?demo or when no backend answers), so a real
// deployment shows honest state instead of roleplay prose masking a dead load path.
fn seedDemo() callconv(.c) void {
    const fixtures = @import("./fixtures.zig");
    _ = fixtures.loadRoleplay(&store.global);
    regions.bumpMessageLog();
}

fn messageViewRenders() callconv(.c) usize {
    return instrument.messageViewRenders();
}

fn shellRenders() callconv(.c) usize {
    return instrument.shellRenders();
}

fn messageLogRenders() callconv(.c) usize {
    return instrument.messageLogRenders();
}

fn composerRenders() callconv(.c) usize {
    return instrument.composerRenders();
}

// w3-grp: a JSON group definition + user text starts a member rotation (group_send.zig).
fn groupSend(ptr: usize, len: usize) callconv(.c) u32 {
    return group_send.beginSendJson(doorBuf(ptr, len));
}

// w3-grp: the glue's stream-failure path, so a rotation cannot wedge on a dead backend.
// C5: the raw document click listener forwards its resolved control here. Buffers are door-allocated
// and freed JS-side after this synchronous call, so telemetry only reads them.
fn onClickTelemetry(
    tag_ptr: usize,
    tag_len: usize,
    id_ptr: usize,
    id_len: usize,
    class_ptr: usize,
    class_len: usize,
    label_ptr: usize,
    label_len: usize,
) callconv(.c) void {
    telemetry.onClick(
        doorBuf(tag_ptr, tag_len),
        doorBuf(id_ptr, id_len),
        doorBuf(class_ptr, class_len),
        doorBuf(label_ptr, label_len),
    );
}

// C5: window error/unhandledrejection forward their prefix + stack/detail here. Same door-buffer
// contract as onClickTelemetry: JS frees after the call returns.
fn onUncaught(
    head_ptr: usize,
    head_len: usize,
    detail_ptr: usize,
    detail_len: usize,
) callconv(.c) void {
    telemetry.onUncaught(
        doorBuf(head_ptr, head_len),
        doorBuf(detail_ptr, detail_len),
    );
}

/// Push a notification from the door. Unlike the append/add exports above, the text is BORROWED:
/// notifications.push copies it, and the caller frees its buffer once this returns.
fn notify(level: u32, text_ptr: usize, text_len: usize, ttl_ms: u32) callconv(.c) void {
    const text = doorBuf(text_ptr, text_len);
    const lvl: notifications.Level = switch (level) {
        1 => .success,
        2 => .warning,
        3 => .err,
        else => .info,
    };
    notifications.push(lvl, text, ttl_ms);
}

/// P1-E: the status poll's arm/disarm, for the interactions gate. The poll is a FALLBACK that the
/// live channel will stand down, so both directions are product surface, not test-only scaffolding.
fn startPoll() callconv(.c) void {
    connection.startPoll();
}

fn stopPoll() callconv(.c) void {
    connection.stopPoll();
}

fn pollArmed() callconv(.c) u32 {
    return @intFromBool(connection.pollArmed());
}

/// P3-A: one live server event, crossing from the glue's EventSource. The id rides ACROSS with the
/// payload because the browser owns the reconnect: after a resume the server replays what the client
/// already saw, and only the id tells them apart. Both buffers are the door's and it frees them.
fn serverEvent(id: u32, name_ptr: usize, name_len: usize, data_ptr: usize, data_len: usize) callconv(.c) void {
    _ = server_events.accept(id, doorBuf(name_ptr, name_len), doorBuf(data_ptr, data_len));
}

/// P3-A: the visibility beacon. Posted from ZIG so it rides net.zig's csrf token and 403-refresh,
/// which the glue has no access to. Returns 0 when there is nothing to report against: the server
/// keys visibility by connection id and answers 404 for one it has never issued, so a beacon before
/// the first `hello` is not a request worth making.
fn visibilityChanged(visible: u32) callconv(.c) u32 {
    const id = server_events.connectionId();
    if (id == 0) return 0;
    var buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"visible\":{s}}}", .{ id, if (visible != 0) "true" else "false" }) catch return 0;
    net.request("/api/events/visibility", body, 0, onVisibilityDone, .{});
    return 1;
}

fn onVisibilityDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (status < 200 or status >= 300) {
        stream_log.warn("visibility beacon rejected: {d}", .{status});
    }
}

fn serverEventStat(which: u32) callconv(.c) u32 {
    const s = server_events.stats();
    return switch (which) {
        0 => s.total,
        1 => s.last_id,
        2 => s.connection_id,
        3 => s.hellos,
        4 => s.replayed,
        5 => s.unknown,
        else => s.applied,
    };
}

/// P3-B: the glue reports the stream dropped. The standalone poll takes the status back until the
/// next hello, so a dead channel does not leave the dot frozen on its last pushed value.
fn serverEventDown() callconv(.c) void {
    server_events.streamDown();
}

/// P3-B: this tab's origin tag, minted in the glue where the browser's crypto lives and handed here
/// before the stream opens. Every mutation carries it as X-ST-Client-Id so the server can skip
/// echoing this tab's own writes back to it.
fn setClientId(ptr: usize, len: usize) callconv(.c) void {
    server_events.setClientId(doorBuf(ptr, len));
}

/// The server could not replay what this client missed, so nothing on the page can be trusted to
/// be current. Every cold path reloads; there is no cheaper honest answer.
fn resyncAll() void {
    char_api.fetchPersonas();
    char_api.fetchCharacters();
    backgrounds.reload();
    wi_actions.reloadList();
    config_state.reloadPresets();
    char_api.reloadCurrentChat();
}

/// P3-B: where each event lands. Wired here rather than in server_events.zig because that module is
/// zx-free so it can join the native test build, and every subsystem below is not.
fn wireLiveRoutes() void {
    server_events.setRoutes(.{
        .resync = resyncAll,
        .settings = char_api.fetchPersonas,
        .background = backgrounds.reload,
        .preset = config_state.reloadPresets,
        .worldinfo = wi_actions.reloadList,
        .chat = char_api.reloadCurrentChat,
        .chat_append = char_api.applyRemoteAppend,
        .character = char_api.fetchCharacters,
        .backend_status = connection.applyServerStatus,
        .stream_up = connection.stopPoll,
        .stream_down = connection.startPoll,
    });
}

comptime {
    if (is_wasm) {
        // Zig owns the data layer (char_api.zig); the append/clear/select/meta exports
        // below stay ONLY for the interactions gate's injection path + console debugging.
        @export(&appendMessage, .{ .name = "__st_append_message" });
        @export(&clearMessages, .{ .name = "__st_clear_messages" });
        @export(&addCharacter, .{ .name = "__st_add_character" });
        @export(&clearCharacters, .{ .name = "__st_clear_characters" });
        @export(&selectCharacter, .{ .name = "__st_select_character" });
        @export(&setCharacterMeta, .{ .name = "__st_set_character_meta" });
        @export(&bootInit, .{ .name = "__st_boot_init" });
        @export(&seedDemo, .{ .name = "__st_seed_demo" });
        @export(&fileReady, .{ .name = "__st_file_ready" }); // C4: File->bytes callback
        @export(&addPersona, .{ .name = "__st_add_persona" });
        @export(&clearPersonas, .{ .name = "__st_clear_personas" });
        @export(&selectPersona, .{ .name = "__st_select_persona" });
        _ = stream_drive; // C2: force-link the streaming orchestrator's exports
        _ = pointer_track; // force-link __st_pointer_move (door D11 ambient pointer reporting)
        // w3-grp
        @export(&groupSend, .{ .name = "__st_group_send" });
        // C5: diagnostics forwarded from the two irreducible JS listeners
        @export(&onClickTelemetry, .{ .name = "__st_on_click_telemetry" });
        @export(&onUncaught, .{ .name = "__st_on_uncaught" });
        // P1-A: the notifications injection path for the interactions gate + console debugging.
        @export(&notify, .{ .name = "__st_notify" });
        // P3-A
        @export(&serverEvent, .{ .name = "__st_server_event" });
        @export(&serverEventStat, .{ .name = "__st_server_event_stat" });
        @export(&visibilityChanged, .{ .name = "__st_visibility_changed" });
        // P3-B
        @export(&serverEventDown, .{ .name = "__st_server_event_down" });
        @export(&setClientId, .{ .name = "__st_set_client_id" });
        // P1-E
        @export(&startPoll, .{ .name = "__st_conn_start_poll" });
        @export(&stopPoll, .{ .name = "__st_conn_stop_poll" });
        @export(&pollArmed, .{ .name = "__st_conn_poll_armed" });
        if (instrument.enabled) {
            @export(&messageViewRenders, .{ .name = "__st_mv_renders" });
            @export(&shellRenders, .{ .name = "__st_shell_renders" });
            @export(&messageLogRenders, .{ .name = "__st_messagelog_renders" });
            @export(&composerRenders, .{ .name = "__st_composer_renders" });
        }
    }
}
