const std = @import("std");
const builtin = @import("builtin");
const store = @import("./store.zig");
const pager = @import("./pager.zig");
const stream_mod = @import("./stream.zig");
const char_store = @import("./character_store.zig");
const character_view = @import("./character_view.zig");
const persona_store = @import("./persona_store.zig");
const persona_actions = @import("./persona_actions.zig");
const card_editor = @import("./card_editor.zig");
const reading_prefs = @import("./reading_prefs.zig");
const appearance = @import("./appearance.zig");
const backgrounds = @import("./backgrounds.zig");
const char_api = @import("./char_api.zig");
const group_send = @import("./group_send.zig"); // w3-grp
const ui = @import("./ui.zig");
const zx = @import("zx");
const regions = @import("./regions.zig");
const instrument = @import("./instrument.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

const chars_log = std.log.scoped(.chars);
const personas_log = std.log.scoped(.personas);
const stream_log = std.log.scoped(.stream);

var live: stream_mod.Stream = .{ .allocator = store.page_gpa, .store = &store.global };

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

fn readerNextBody() callconv(.c) u64 {
    return pager.nextBody();
}

fn readerApplyPage(ptr: usize, len: usize) callconv(.c) u32 {
    return pager.applyPage(doorBuf(ptr, len));
}

fn readerCanPrepend() callconv(.c) u32 {
    return @intFromBool(pager.canPrepend());
}

fn readerResync() callconv(.c) void {
    pager.beginResync();
    char_api.reloadCurrentChat();
}

fn readerAbort() callconv(.c) void {
    pager.abort();
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
}

/// Reload the character store from the backend. Called by the JS multipart helpers
/// (import, avatar) after a successful upload; everything else refreshes inside char_api.
fn refreshCharacters() callconv(.c) void {
    char_api.fetchCharacters();
}

/// Called by the __st_persona_avatar JS multipart helper after a successful persona-avatar upload,
/// so the persona panel re-renders against the new image (C-PERS).
fn personaAvatarUploaded() callconv(.c) void {
    persona_actions.onAvatarUploaded();
}

/// Called by the __st_card_avatar JS multipart helper once the card-image upload settles, either
/// way: the card editor states the outcome in its own footer, so it needs the failure too (C-CARD2).
/// Carries the HTTP status, 0 meaning the request never completed.
fn cardAvatarUploaded(status: i32) callconv(.c) void {
    card_editor.onAvatarUploaded(status);
}

/// Called by the __st_bg_upload JS multipart helper once the background upload settles, on every
/// path it takes, including a cancelled picker. Carries the HTTP status, 0 meaning the request never
/// completed. uploadPick has already drawn its wait state by then and uploadDone is the only thing
/// that clears it, so this export is not optional: without it the helper's call throws, the wait
/// never lifts, and the panel spins over a file that already uploaded.
fn backgroundUploaded(status: i32) callconv(.c) void {
    backgrounds.uploadDone(status);
}

// Demo fixtures are opt-in (glue calls this on ?demo or when no backend answers), so a real
// deployment shows honest state instead of roleplay prose masking a dead load path.
fn seedDemo() callconv(.c) void {
    const fixtures = @import("./fixtures.zig");
    _ = fixtures.loadRoleplay(&store.global);
    regions.bumpMessageLog();
}

fn streamBegin(name_ptr: usize, name_len: usize, avatar_ptr: usize, avatar_len: usize) callconv(.c) u32 {
    const name = doorBuf(name_ptr, name_len);
    const avatar = doorBuf(avatar_ptr, avatar_len);
    live.begin(name, avatar) catch |err| {
        store.global.allocator.free(name);
        store.global.allocator.free(avatar);
        stream_log.err("stream_begin: {s}, stream not started", .{@errorName(err)});
        return 1;
    };
    regions.bumpMessageLog();
    return 0;
}

fn streamAppend(ptr: usize, len: usize) callconv(.c) void {
    const buf = doorBuf(ptr, len);
    defer store.global.allocator.free(buf);
    live.feed(buf) catch |err| {
        stream_log.err("stream_append: {s}, stream sealed early", .{@errorName(err)});
        live.end();
    };
    regions.bumpMessageLog();
}

fn streamEnd() callconv(.c) void {
    live.end();
    regions.bumpMessageLog();
}

fn streamTokens() callconv(.c) usize {
    return live.tokens;
}

/// Called by the JS pump after a send's stream seals: persist the assistant reply (char_api owns the
/// append). The user turn is persisted synchronously on send, so this handles the reply half only.
fn persistTurns() callconv(.c) void {
    char_api.persistNewTurns();
}

fn streamDone() callconv(.c) u32 {
    return @intFromBool(live.state == .done);
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
fn groupStreamFailed() callconv(.c) void {
    group_send.onStreamFailed();
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
        @export(&refreshCharacters, .{ .name = "__st_refresh_characters" });
        @export(&personaAvatarUploaded, .{ .name = "__st_persona_avatar_done" });
        @export(&cardAvatarUploaded, .{ .name = "__st_card_avatar_done" });
        @export(&backgroundUploaded, .{ .name = "__st_bg_upload_done" });
        @export(&addPersona, .{ .name = "__st_add_persona" });
        @export(&clearPersonas, .{ .name = "__st_clear_personas" });
        @export(&selectPersona, .{ .name = "__st_select_persona" });
        @export(&streamBegin, .{ .name = "__st_stream_begin" });
        @export(&streamAppend, .{ .name = "__st_stream_append" });
        @export(&streamEnd, .{ .name = "__st_stream_end" });
        @export(&streamTokens, .{ .name = "__st_stream_tokens" });
        @export(&streamDone, .{ .name = "__st_stream_done" });
        @export(&persistTurns, .{ .name = "__st_persist_turns" });
        @export(&readerNextBody, .{ .name = "__st_reader_next_body" });
        @export(&readerApplyPage, .{ .name = "__st_reader_apply_page" });
        @export(&readerCanPrepend, .{ .name = "__st_reader_can_prepend" });
        @export(&readerResync, .{ .name = "__st_reader_resync" });
        @export(&readerAbort, .{ .name = "__st_reader_abort" });
        // w3-grp
        @export(&groupSend, .{ .name = "__st_group_send" });
        @export(&groupStreamFailed, .{ .name = "__st_group_stream_failed" });
        if (instrument.enabled) {
            @export(&messageViewRenders, .{ .name = "__st_mv_renders" });
            @export(&shellRenders, .{ .name = "__st_shell_renders" });
            @export(&messageLogRenders, .{ .name = "__st_messagelog_renders" });
            @export(&composerRenders, .{ .name = "__st_composer_renders" });
        }
    }
}
