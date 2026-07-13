const std = @import("std");
const builtin = @import("builtin");
const store = @import("./store.zig");
const stream_mod = @import("./stream.zig");
const char_store = @import("./character_store.zig");
const regions = @import("./regions.zig");
const instrument = @import("./instrument.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

var live: stream_mod.Stream = .{ .allocator = store.page_gpa, .store = &store.global };

fn doorBuf(addr: usize, len: usize) []u8 {
    if (addr == 0 or len == 0) return &.{};
    return @as([*]u8, @ptrFromInt(addr))[0..len];
}

fn appendMessage(name_ptr: usize, name_len: usize, body_ptr: usize, body_len: usize) callconv(.c) void {
    const name = doorBuf(name_ptr, name_len);
    const body = doorBuf(body_ptr, body_len);
    store.global.append(name, body) catch |err| {
        store.global.allocator.free(name);
        store.global.allocator.free(body);
        std.log.err("append_message: {s}, message dropped", .{@errorName(err)});
        return;
    };
    regions.bumpMessageLog();
}

fn clearMessages() callconv(.c) void {
    store.global.clear();
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
        std.log.err("add_character: {s}, character dropped", .{@errorName(err)});
    };
    regions.bumpShell();
}

fn clearCharacters() callconv(.c) void {
    char_store.global.clear();
    regions.bumpShell();
}

fn selectCharacter(index: u32) callconv(.c) void {
    char_store.global.select(@intCast(index));
    regions.bumpShell();
}

fn streamBegin(name_ptr: usize, name_len: usize) callconv(.c) u32 {
    const name = doorBuf(name_ptr, name_len);
    live.begin(name) catch |err| {
        store.global.allocator.free(name);
        std.log.err("stream_begin: {s}, stream not started", .{@errorName(err)});
        return 1;
    };
    regions.bumpMessageLog();
    return 0;
}

fn streamAppend(ptr: usize, len: usize) callconv(.c) void {
    const buf = doorBuf(ptr, len);
    defer store.global.allocator.free(buf);
    live.feed(buf) catch |err| {
        std.log.err("stream_append: {s}, stream sealed early", .{@errorName(err)});
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

comptime {
    if (is_wasm) {
        @export(&appendMessage, .{ .name = "__st_append_message" });
        @export(&clearMessages, .{ .name = "__st_clear_messages" });
        @export(&addCharacter, .{ .name = "__st_add_character" });
        @export(&clearCharacters, .{ .name = "__st_clear_characters" });
        @export(&selectCharacter, .{ .name = "__st_select_character" });
        @export(&streamBegin, .{ .name = "__st_stream_begin" });
        @export(&streamAppend, .{ .name = "__st_stream_append" });
        @export(&streamEnd, .{ .name = "__st_stream_end" });
        @export(&streamTokens, .{ .name = "__st_stream_tokens" });
        @export(&streamDone, .{ .name = "__st_stream_done" });
        if (instrument.enabled) {
            @export(&messageViewRenders, .{ .name = "__st_mv_renders" });
            @export(&shellRenders, .{ .name = "__st_shell_renders" });
            @export(&messageLogRenders, .{ .name = "__st_messagelog_renders" });
            @export(&composerRenders, .{ .name = "__st_composer_renders" });
        }
    }
}
