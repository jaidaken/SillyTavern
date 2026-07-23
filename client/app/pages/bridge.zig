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
const zx = @import("zx");
const regions = @import("./regions.zig");
const reveal = @import("./reveal.zig");
const instrument = @import("./instrument.zig");
const telemetry = @import("./telemetry.zig"); // C5: uncaught-error + click diagnostics log here
const stream_drive = @import("./stream_drive.zig"); // C2: Zig-owned SSE lifecycle + door pump driver
const notifications = @import("./notifications.zig");

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
        // w3-grp
        @export(&groupSend, .{ .name = "__st_group_send" });
        // C5: diagnostics forwarded from the two irreducible JS listeners
        @export(&onClickTelemetry, .{ .name = "__st_on_click_telemetry" });
        @export(&onUncaught, .{ .name = "__st_on_uncaught" });
        // P1-A: the notifications injection path for the interactions gate + console debugging.
        @export(&notify, .{ .name = "__st_notify" });
        if (instrument.enabled) {
            @export(&messageViewRenders, .{ .name = "__st_mv_renders" });
            @export(&shellRenders, .{ .name = "__st_shell_renders" });
            @export(&messageLogRenders, .{ .name = "__st_messagelog_renders" });
            @export(&composerRenders, .{ .name = "__st_composer_renders" });
        }
    }
}
