//! Pure data layer for the character/persona/chat backend contracts: JSON shapes, tolerant
//! field coercion, boot decisions, and the small string transforms the chat flow needs.
//! No zx import, so the whole module runs under `zig build test` (ZX5 split); the fetch and
//! DOM halves live in net.zig and char_api.zig, which are browser-verified.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Character = @import("./character_store.zig").Character;

/// One character as /api/characters/all returns it (the shallow form). Types are tolerant on
/// purpose: real card data carries fav as bool OR string, and the numeric metadata may be
/// absent. Unknown fields are ignored by the parse options (see parseJson).
/// The card fields below are NOT typed `[]const u8`, and that is deliberate. The server reads them
/// straight out of the card's own PNG JSON and passes them through UNCOERCED (characters.js:426-430:
/// `const character = jsonObject; character.create_date = jsonObject.create_date || ...`), so a card
/// written by another tool can carry any JSON shape at all. Typed as a string, ONE such card does not
/// merely render oddly: it fails the WHOLE array parse and the user sees ZERO characters. `avatar`,
/// `date_last_chat`, `chat_size` and `data_size` stay typed because the SERVER sets them (it assigns
/// the filename and computes the sizes), so a wrong shape there is a broken contract worth failing on.
pub const CharacterJson = struct {
    name: std.json.Value = .null,
    avatar: []const u8 = "",
    description: std.json.Value = .null,
    chat: std.json.Value = .null,
    first_mes: std.json.Value = .null,
    fav: std.json.Value = .null,
    tags: std.json.Value = .null,
    create_date: std.json.Value = .null,
    date_last_chat: ?f64 = null,
    chat_size: ?f64 = null,
    data_size: ?f64 = null,
};

/// The string a loosely-typed JSON field carries, or "" for any other shape. Borrowed from the
/// parse; copy it to retain.
pub fn jsonStr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string, .number_string => |s| s,
        else => "",
    };
}

/// The one field of /api/settings/get the client reads; the rest is ignored.
pub const SettingsJson = struct {
    settings: ?[]const u8 = null,
};

/// Same options as ziex's Response.json (core/Fetch.zig), so the native tests below parse
/// exactly what the browser path parses.
pub fn parseJson(comptime T: type, alloc: Allocator, body: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// JS truthiness for the fav field, matching the deleted glue's `c.fav ? 1 : 0`: any
/// non-empty string counts as true, INCLUDING the string "false" (old card data quirk the
/// old frontend shared).
pub fn favTruthy(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        .string => |s| s.len > 0,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        else => false,
    };
}

/// The card's tags as an owned slice of owned strings. Cards from other tools carry tags in any
/// shape: only an array yields tags, and a non-string or empty entry costs that entry, never the
/// card. Free with freeTags.
pub fn tagsAlloc(gpa: Allocator, v: std.json.Value) Allocator.Error![]const []const u8 {
    const arr = switch (v) {
        .array => |a| a,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| gpa.free(t);
        out.deinit(gpa);
    }
    for (arr.items) |item| {
        const s = jsonStr(item);
        if (s.len == 0) continue;
        // ensureUnusedCapacity first: `append(dupe(...))` leaks the dupe when the append fails.
        try out.ensureUnusedCapacity(gpa, 1);
        out.appendAssumeCapacity(try gpa.dupe(u8, s));
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return &.{};
    }
    return try out.toOwnedSlice(gpa);
}

/// Frees a tagsAlloc result. The empty result is the static slice and owns nothing.
pub fn freeTags(gpa: Allocator, tags: []const []const u8) void {
    if (tags.len == 0) return;
    for (tags) |t| gpa.free(t);
    gpa.free(tags);
}

/// Numeric metadata to u64, matching the glue's `BigInt(Math.trunc(v) || 0)`: absent, NaN,
/// negative, and out-of-range values all collapse to 0.
pub fn metaU64(v: ?f64) u64 {
    const f = v orelse return 0;
    if (!std.math.isFinite(f) or f <= 0) return 0;
    const t = @trunc(f);
    if (t >= 18446744073709551615.0) return std.math.maxInt(u64);
    return @intFromFloat(t);
}

/// URLSearchParams.has semantics over location.search: the flag matches as a bare token or
/// with a value, never as a prefix of another key.
pub fn hasQueryFlag(search: []const u8, flag: []const u8) bool {
    var s = search;
    if (s.len > 0 and s[0] == '?') s = s[1..];
    var it = std.mem.splitScalar(u8, s, '&');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, flag)) return true;
        if (tok.len > flag.len and std.mem.startsWith(u8, tok, flag) and tok[flag.len] == '=') return true;
    }
    return false;
}

pub const PersonaJson = struct {
    avatar: []u8,
    name: []u8,
    description: []u8,
};

pub const PersonasError = error{ ParseFailed, NotAnObject } || Allocator.Error;

/// Personas from the settings blob: /api/settings/get returns { settings: "<json string>" },
/// and inside that string power_user.personas maps avatar file -> display name, with
/// power_user.persona_descriptions keyed the same way. Missing power_user or personas is a
/// valid empty result; a settings string that is not JSON, or not an object, is an error the
/// caller warns about. The returned slice and every field are owned; free with freePersonas.
pub fn extractPersonas(alloc: Allocator, settings_str: []const u8) PersonasError![]PersonaJson {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, settings_str, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseFailed,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    const power_user = switch (root.get("power_user") orelse return alloc.alloc(PersonaJson, 0)) {
        .object => |o| o,
        else => return alloc.alloc(PersonaJson, 0),
    };
    const personas = switch (power_user.get("personas") orelse return alloc.alloc(PersonaJson, 0)) {
        .object => |o| o,
        else => return alloc.alloc(PersonaJson, 0),
    };
    const descs: ?std.json.ObjectMap = if (power_user.get("persona_descriptions")) |d| switch (d) {
        .object => |o| o,
        else => null,
    } else null;

    var out: std.ArrayList(PersonaJson) = .empty;
    errdefer {
        for (out.items) |p| freePersona(alloc, p);
        out.deinit(alloc);
    }
    var it = personas.iterator();
    while (it.next()) |entry| {
        const avatar_file = entry.key_ptr.*;
        if (avatar_file.len == 0) continue;
        const raw_name: []const u8 = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => "",
        };
        const name_src = if (raw_name.len > 0) raw_name else "Persona";
        const desc_src: []const u8 = if (descs) |d| blk: {
            const dv = d.get(avatar_file) orelse break :blk "";
            break :blk switch (dv) {
                .string => |s| s,
                else => "",
            };
        } else "";

        const avatar = try alloc.dupe(u8, avatar_file);
        errdefer alloc.free(avatar);
        const name = try alloc.dupe(u8, name_src);
        errdefer alloc.free(name);
        const description = try alloc.dupe(u8, desc_src);
        errdefer alloc.free(description);
        try out.append(alloc, .{ .avatar = avatar, .name = name, .description = description });
    }
    return try out.toOwnedSlice(alloc);
}

fn freePersona(alloc: Allocator, p: PersonaJson) void {
    alloc.free(p.avatar);
    alloc.free(p.name);
    alloc.free(p.description);
}

pub fn freePersonas(alloc: Allocator, list: []PersonaJson) void {
    for (list) |p| freePersona(alloc, p);
    alloc.free(list);
}

/// One stored chat turn. `is_system` marks a narrator/system line, which the store's Message has
/// carried all along (store.zig:32) but this struct did NOT, even though the PROMPT path reads THIS
/// one: a narrator turn therefore wrapped as the character's own speech and the model answered as if
/// the scene description had come from the character. Parsed here so the role reaches generate.
pub const ChatMsg = struct {
    name: []u8,
    mes: []u8,
    is_user: bool,
    is_system: bool = false,
    /// The turn's thinking text (extra.reasoning in the chat file); empty when absent. Owned.
    reasoning: []u8 = &.{},
};

/// Chat messages from a parsed /api/chats/get body. The server contract: element 0 is chat
/// metadata, the rest are messages; a non-array or single-element body means "no chat yet"
/// (the caller seeds the greeting). Non-object elements degrade to empty fields, matching
/// the old glue's undefined-field reads. Owned result; free with freeChatMessages.
pub fn chatMessages(alloc: Allocator, root: std.json.Value) Allocator.Error![]ChatMsg {
    const arr = switch (root) {
        .array => |a| a,
        else => return alloc.alloc(ChatMsg, 0),
    };
    if (arr.items.len <= 1) return alloc.alloc(ChatMsg, 0);

    var out: std.ArrayList(ChatMsg) = .empty;
    errdefer {
        for (out.items) |m| {
            alloc.free(m.name);
            alloc.free(m.mes);
            alloc.free(m.reasoning);
        }
        out.deinit(alloc);
    }
    for (arr.items[1..]) |item| {
        var name_src: []const u8 = "";
        var mes_src: []const u8 = "";
        var is_user = false;
        var is_system = false;
        var reasoning_src: []const u8 = "";
        switch (item) {
            .object => |o| {
                if (o.get("name")) |v| switch (v) {
                    .string => |s| name_src = s,
                    else => {},
                };
                if (o.get("mes")) |v| switch (v) {
                    .string => |s| mes_src = s,
                    else => {},
                };
                if (o.get("is_user")) |v| is_user = favTruthy(v);
                if (o.get("is_system")) |v| is_system = favTruthy(v);
                if (o.get("extra")) |v| switch (v) {
                    .object => |e| if (e.get("reasoning")) |rv| switch (rv) {
                        .string => |s| reasoning_src = s,
                        else => {},
                    },
                    else => {},
                };
            },
            else => {},
        }
        const name = try alloc.dupe(u8, name_src);
        errdefer alloc.free(name);
        const mes = try alloc.dupe(u8, mes_src);
        errdefer alloc.free(mes);
        const reasoning = try alloc.dupe(u8, reasoning_src);
        errdefer alloc.free(reasoning);
        try out.append(alloc, .{ .name = name, .mes = mes, .is_user = is_user, .is_system = is_system, .reasoning = reasoning });
    }
    return try out.toOwnedSlice(alloc);
}

pub fn freeChatMessages(alloc: Allocator, list: []ChatMsg) void {
    for (list) |m| {
        alloc.free(m.name);
        alloc.free(m.mes);
        alloc.free(m.reasoning);
    }
    alloc.free(list);
}

/// A page of the paged /api/chats/get envelope. `messages` is the window slice (already
/// header-stripped by the server), oldest first. `change_token` is the opaque token to send
/// back on the next `before_index` request; `total_items` and `has_more_before` drive the
/// window bookkeeping. Owned result; free with freeChatPage.
/// `chat_metadata` is the chat file's own header (buildChatPage returns it as `header`), which is
/// where the classic client keeps the author's note. Carried as a raw JSON string rather than a
/// parsed tree so it survives the caller's json arena; empty when the page had no header.
pub const ChatPage = struct {
    messages: []ChatMsg,
    total_items: usize,
    has_more_before: bool,
    change_token: []u8,
    chat_metadata: []u8,
    /// The token covering the WHOLE file, which the mutation family gates on (the tail token hashes
    /// only the head, so two concurrent in-window edits would both pass it and one would be lost).
    /// buildChatPage emits it on every page so a windowed client always holds a current one.
    full_token: []u8,
};

fn valueMessages(alloc: Allocator, v: std.json.Value) Allocator.Error![]ChatMsg {
    const arr = switch (v) {
        .array => |a| a,
        else => return alloc.alloc(ChatMsg, 0),
    };
    var out: std.ArrayList(ChatMsg) = .empty;
    errdefer {
        for (out.items) |m| {
            alloc.free(m.name);
            alloc.free(m.mes);
            alloc.free(m.reasoning);
        }
        out.deinit(alloc);
    }
    for (arr.items) |item| {
        var name_src: []const u8 = "";
        var mes_src: []const u8 = "";
        var is_user = false;
        var is_system = false;
        var reasoning_src: []const u8 = "";
        switch (item) {
            .object => |o| {
                if (o.get("name")) |x| switch (x) {
                    .string => |s| name_src = s,
                    else => {},
                };
                if (o.get("mes")) |x| switch (x) {
                    .string => |s| mes_src = s,
                    else => {},
                };
                if (o.get("is_user")) |x| is_user = favTruthy(x);
                if (o.get("is_system")) |x| is_system = favTruthy(x);
                if (o.get("extra")) |x| switch (x) {
                    .object => |e| if (e.get("reasoning")) |rv| switch (rv) {
                        .string => |s| reasoning_src = s,
                        else => {},
                    },
                    else => {},
                };
            },
            else => {},
        }
        const name = try alloc.dupe(u8, name_src);
        errdefer alloc.free(name);
        const mes = try alloc.dupe(u8, mes_src);
        errdefer alloc.free(mes);
        const reasoning = try alloc.dupe(u8, reasoning_src);
        errdefer alloc.free(reasoning);
        try out.append(alloc, .{ .name = name, .mes = mes, .is_user = is_user, .is_system = is_system, .reasoning = reasoning });
    }
    return try out.toOwnedSlice(alloc);
}

/// Parses the paged envelope. A non-object root, or a missing/mistyped field, degrades to an
/// empty window with an empty token rather than erroring, so a malformed page is treated as
/// "nothing to add" and the caller keeps its current state.
pub fn parseChatPage(alloc: Allocator, root: std.json.Value) Allocator.Error!ChatPage {
    const obj = switch (root) {
        .object => |o| o,
        else => return .{ .messages = try alloc.alloc(ChatMsg, 0), .total_items = 0, .has_more_before = false, .change_token = try alloc.dupe(u8, ""), .chat_metadata = try alloc.dupe(u8, ""), .full_token = try alloc.dupe(u8, "") },
    };
    const messages = try valueMessages(alloc, obj.get("messages") orelse .null);
    errdefer freeChatMessages(alloc, messages);
    const chat_metadata = try metadataJson(alloc, obj);
    errdefer alloc.free(chat_metadata);

    var total: usize = messages.len;
    if (obj.get("total_items")) |v| switch (v) {
        .integer => |i| total = if (i >= 0) @intCast(i) else 0,
        else => {},
    };
    var has_more = false;
    if (obj.get("has_more_before")) |v| switch (v) {
        .bool => |b| has_more = b,
        else => {},
    };
    const token_src: []const u8 = if (obj.get("change_token")) |v| switch (v) {
        .string => |s| s,
        else => "",
    } else "";
    const change_token = try alloc.dupe(u8, token_src);
    errdefer alloc.free(change_token);
    const full_src: []const u8 = if (obj.get("full_token")) |v| switch (v) {
        .string => |s| s,
        else => "",
    } else "";
    const full_token = try alloc.dupe(u8, full_src);
    return .{ .messages = messages, .total_items = total, .has_more_before = has_more, .change_token = change_token, .chat_metadata = chat_metadata, .full_token = full_token };
}

/// The page header's `chat_metadata`, re-stringified so it outlives the response's json arena. A
/// missing or non-object header yields "", which the author's-note parse reads as "no note".
fn metadataJson(alloc: Allocator, obj: std.json.ObjectMap) Allocator.Error![]u8 {
    const header = obj.get("header") orelse return alloc.dupe(u8, "");
    if (header != .object) return alloc.dupe(u8, "");
    const meta = header.object.get("chat_metadata") orelse return alloc.dupe(u8, "");
    if (meta != .object) return alloc.dupe(u8, "");
    return std.json.Stringify.valueAlloc(alloc, meta, .{});
}

pub fn freeChatPage(alloc: Allocator, page: ChatPage) void {
    freeChatMessages(alloc, page.messages);
    alloc.free(page.change_token);
    alloc.free(page.chat_metadata);
    alloc.free(page.full_token);
}

/// w3-chatref: which server chat file a paged read addresses, the client half of the server's
/// ChatRef: a solo chat (chats/<avatar>/<file>.jsonl) or a group chat (groupChats/<id>.jsonl).
/// One reader path serves both (invariant 5); only the route and the body's identity keys differ.
pub const ChatRef = union(enum) {
    solo: struct { avatar: []const u8, file: []const u8 },
    group: struct { id: []const u8 },

    /// The paged read route this ref addresses.
    pub fn url(self: ChatRef) []const u8 {
        return switch (self) {
            .solo => "/api/chats/get",
            .group => "/api/chats/group/get",
        };
    }

    /// True when the ref names a fetchable chat: both solo parts, or a non-empty group id.
    pub fn valid(self: ChatRef) bool {
        return switch (self) {
            .solo => |s| s.avatar.len > 0 and s.file.len > 0,
            .group => |g| g.id.len > 0,
        };
    }
};

/// w3-chatref: one paged chat read: a tail window (no before_index), a scroll-up prepend
/// (before_index + change_token), or a prompt window (a larger limit).
pub const PageOpts = struct {
    limit: usize,
    before_index: ?usize = null,
    change_token: ?[]const u8 = null,
};

/// w3-chatref: the JSON body for a paged chat read over `ref`. Unset optionals are omitted, not
/// null, so the solo tail body keeps the exact shape the server's readPageOpts always saw.
pub fn pageBody(alloc: Allocator, ref: ChatRef, opts: PageOpts) Allocator.Error![]u8 {
    const o = std.json.Stringify.Options{ .emit_null_optional_fields = false };
    return switch (ref) {
        .solo => |s| std.json.Stringify.valueAlloc(alloc, .{
            .avatar_url = s.avatar,
            .file_name = s.file,
            .paged = true,
            .limit = opts.limit,
            .before_index = opts.before_index,
            .change_token = opts.change_token,
        }, o),
        .group => |g| std.json.Stringify.valueAlloc(alloc, .{
            .id = g.id,
            .paged = true,
            .limit = opts.limit,
            .before_index = opts.before_index,
            .change_token = opts.change_token,
        }, o),
    };
}

/// First-message greeting with the {{char}}/{{user}} macros substituted (both, every
/// occurrence), as the old glue's replaceAll pair did. Owned result.
pub fn renderGreeting(alloc: Allocator, first_mes: []const u8, char_name: []const u8, user_name: []const u8) Allocator.Error![]u8 {
    const pass1 = try std.mem.replaceOwned(u8, alloc, first_mes, "{{char}}", char_name);
    defer alloc.free(pass1);
    return std.mem.replaceOwned(u8, alloc, pass1, "{{user}}", user_name);
}

/// Index of the most recently chatted character (ties keep the first, as the old glue's
/// strict `>` comparison did). Null only when the store is empty.
pub fn mostRecentIndex(chars: []const Character) ?usize {
    if (chars.len == 0) return null;
    var best: usize = 0;
    for (chars, 0..) |c, i| {
        if (c.date_last_chat > chars[best].date_last_chat) best = i;
    }
    return best;
}

/// encodeURIComponent: everything but the unreserved set (A-Z a-z 0-9 - _ . ! ~ * ' ( ))
/// percent-encodes, byte-wise over UTF-8. Owned result.
pub fn encodeUriComponent(alloc: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |b| {
        const keep = switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
            else => false,
        };
        if (keep) {
            try out.append(alloc, b);
        } else {
            const hex = "0123456789ABCDEF";
            try out.append(alloc, '%');
            try out.append(alloc, hex[b >> 4]);
            try out.append(alloc, hex[b & 0xf]);
        }
    }
    return try out.toOwnedSlice(alloc);
}

/// "../thumbnail?type=<kind>&file=<encoded>" as the old glue built it. Owned result.
pub fn thumbUrl(alloc: Allocator, kind: []const u8, file: []const u8) Allocator.Error![]u8 {
    const enc = try encodeUriComponent(alloc, file);
    defer alloc.free(enc);
    return std.fmt.allocPrint(alloc, "../thumbnail?type={s}&file={s}", .{ kind, enc });
}

/// UTC calendar date (YYYY-MM-DD) for an epoch-milliseconds stamp; non-finite or negative
/// input degrades to the epoch. Formats into the caller's buffer.
pub fn isoDateFromMs(ms: f64, buf: *[10]u8) []const u8 {
    var secs: u64 = 0;
    if (std.math.isFinite(ms) and ms > 0) secs = @intFromFloat(@trunc(ms / 1000.0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var w: std.Io.Writer = .fixed(buf);
    w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    }) catch {};
    return w.buffered();
}

const testing = std.testing;

test "hasQueryFlag matches bare and valued tokens only" {
    try testing.expect(hasQueryFlag("?demo=1", "demo"));
    try testing.expect(hasQueryFlag("?demo", "demo"));
    try testing.expect(hasQueryFlag("?a=1&demo", "demo"));
    try testing.expect(!hasQueryFlag("?stream=demo", "demo"));
    try testing.expect(!hasQueryFlag("?ademo=1", "demo"));
    try testing.expect(!hasQueryFlag("?demoo=1", "demo"));
    try testing.expect(!hasQueryFlag("", "demo"));
}

test "favTruthy mirrors JS truthiness including the string-false quirk" {
    try testing.expect(favTruthy(.{ .bool = true }));
    try testing.expect(!favTruthy(.{ .bool = false }));
    try testing.expect(favTruthy(.{ .string = "false" }));
    try testing.expect(!favTruthy(.{ .string = "" }));
    try testing.expect(!favTruthy(.null));
    try testing.expect(!favTruthy(.{ .integer = 0 }));
    try testing.expect(favTruthy(.{ .integer = 1 }));
}

test "metaU64 truncates and collapses absent or invalid values to zero" {
    try testing.expectEqual(@as(u64, 0), metaU64(null));
    try testing.expectEqual(@as(u64, 0), metaU64(std.math.nan(f64)));
    try testing.expectEqual(@as(u64, 0), metaU64(-5.0));
    try testing.expectEqual(@as(u64, 1783800000000), metaU64(1783800000000.0));
    try testing.expectEqual(@as(u64, 3), metaU64(3.9));
}

test "parseJson tolerates unknown fields and missing metadata on characters" {
    const body =
        \\[{"name":"Rita","avatar":"rita.png","description":"d","chat":"Rita - x",
        \\  "first_mes":"Hi {{user}}","fav":"false","date_last_chat":1783800000000,
        \\  "spec":"chara_card_v2","unknown_deep":{"a":[1,2]}},
        \\ {"name":"Min","avatar":"min.png"}]
    ;
    const parsed = try parseJson([]CharacterJson, testing.allocator, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.len);
    try testing.expectEqualStrings("Rita", jsonStr(parsed.value[0].name));
    try testing.expect(favTruthy(parsed.value[0].fav));
    try testing.expectEqual(@as(u64, 1783800000000), metaU64(parsed.value[0].date_last_chat));
    try testing.expectEqualStrings("", jsonStr(parsed.value[1].chat));
    try testing.expectEqual(@as(u64, 0), metaU64(parsed.value[1].chat_size));
}

test "one card with an odd field shape costs that field, never the whole list" {
    // Typed as strings these failed the WHOLE array parse and the user saw ZERO characters. The odd
    // card sits BETWEEN two good ones, so a parse that bails at the first bad field still fails this.
    const body =
        \\[{"name":"Good","avatar":"a.png","description":"d","create_date":"2026-07-01"},
        \\ {"name":"Odd","avatar":"b.png","description":null,"create_date":1700000000000,
        \\  "chat":42,"first_mes":["not","a","string"]},
        \\ {"name":"AlsoGood","avatar":"c.png","description":"d","create_date":"2026-07-02"}]
    ;
    const parsed = try parseJson([]CharacterJson, testing.allocator, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.len);

    // The good cards are untouched.
    try testing.expectEqualStrings("Good", jsonStr(parsed.value[0].name));
    try testing.expectEqualStrings("2026-07-01", jsonStr(parsed.value[0].create_date));
    try testing.expectEqualStrings("AlsoGood", jsonStr(parsed.value[2].name));

    // The odd card loads, and every field the client cannot read reads as empty rather than wrong.
    try testing.expectEqualStrings("Odd", jsonStr(parsed.value[1].name));
    try testing.expectEqualStrings("", jsonStr(parsed.value[1].description));
    try testing.expectEqualStrings("", jsonStr(parsed.value[1].create_date));
    try testing.expectEqualStrings("", jsonStr(parsed.value[1].chat));
    try testing.expectEqualStrings("", jsonStr(parsed.value[1].first_mes));
}

test "parseJson yields null settings when the field is absent" {
    const parsed = try parseJson(SettingsJson, testing.allocator, "{\"other\":1}");
    defer parsed.deinit();
    try testing.expectEqual(@as(?[]const u8, null), parsed.value.settings);
}

test "extractPersonas walks personas with descriptions and name fallback" {
    const settings =
        \\{"power_user":{"personas":{"p1.png":"Alice","p2.png":""},
        \\  "persona_descriptions":{"p1.png":"First persona"}}}
    ;
    const list = try extractPersonas(testing.allocator, settings);
    defer freePersonas(testing.allocator, list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("p1.png", list[0].avatar);
    try testing.expectEqualStrings("Alice", list[0].name);
    try testing.expectEqualStrings("First persona", list[0].description);
    try testing.expectEqualStrings("Persona", list[1].name);
    try testing.expectEqualStrings("", list[1].description);
}

test "extractPersonas distinguishes malformed, non-object, and empty cases" {
    try testing.expectError(error.ParseFailed, extractPersonas(testing.allocator, "{nope"));
    try testing.expectError(error.NotAnObject, extractPersonas(testing.allocator, "42"));
    const empty = try extractPersonas(testing.allocator, "{\"power_user\":{}}");
    defer freePersonas(testing.allocator, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    const no_pu = try extractPersonas(testing.allocator, "{}");
    defer freePersonas(testing.allocator, no_pu);
    try testing.expectEqual(@as(usize, 0), no_pu.len);
}

test "extractPersonas cleans up on every allocation failure" {
    const settings =
        \\{"power_user":{"personas":{"p1.png":"Alice","p2.png":"Bob"},
        \\  "persona_descriptions":{"p1.png":"First"}}}
    ;
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, s: []const u8) !void {
            const list = try extractPersonas(alloc, s);
            freePersonas(alloc, list);
        }
    }.run, .{@as([]const u8, settings)});
}

test "chatMessages skips the metadata head and reads name, mes, is_user" {
    const body =
        \\[{"user_name":"You","chat_metadata":{}},
        \\ {"name":"Rita","is_user":false,"mes":"Hello."},
        \\ {"name":"You","is_user":true,"mes":"Hi."},
        \\ 7]
    ;
    const parsed = try parseJson(std.json.Value, testing.allocator, body);
    defer parsed.deinit();
    const msgs = try chatMessages(testing.allocator, parsed.value);
    defer freeChatMessages(testing.allocator, msgs);
    try testing.expectEqual(@as(usize, 3), msgs.len);
    try testing.expectEqualStrings("Rita", msgs[0].name);
    try testing.expectEqualStrings("Hello.", msgs[0].mes);
    try testing.expect(!msgs[0].is_user);
    try testing.expect(msgs[1].is_user);
    try testing.expectEqualStrings("", msgs[2].name);
}

test "chatMessages returns empty for non-array and single-element bodies" {
    const obj = try parseJson(std.json.Value, testing.allocator, "{}");
    defer obj.deinit();
    const none = try chatMessages(testing.allocator, obj.value);
    defer freeChatMessages(testing.allocator, none);
    try testing.expectEqual(@as(usize, 0), none.len);

    const meta_only = try parseJson(std.json.Value, testing.allocator, "[{\"chat_metadata\":{}}]");
    defer meta_only.deinit();
    const still_none = try chatMessages(testing.allocator, meta_only.value);
    defer freeChatMessages(testing.allocator, still_none);
    try testing.expectEqual(@as(usize, 0), still_none.len);
}

test "chatMessages cleans up on every allocation failure" {
    const parsed = try parseJson(std.json.Value, testing.allocator, "[{},{\"name\":\"A\",\"mes\":\"m\"},{\"name\":\"B\",\"mes\":\"n\"}]");
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, v: std.json.Value) !void {
            const msgs = try chatMessages(alloc, v);
            freeChatMessages(alloc, msgs);
        }
    }.run, .{parsed.value});
}

test "parseChatPage reads the window, total, has_more, and token" {
    const body =
        \\{"messages":[{"name":"Rita","is_user":false,"mes":"Older one."},
        \\ {"name":"You","is_user":true,"mes":"Older two."}],
        \\ "header":{"user_name":"You"},"change_token":"v1.42.abc",
        \\ "has_more_before":true,"has_more_after":false,"total_items":42}
    ;
    const parsed = try parseJson(std.json.Value, testing.allocator, body);
    defer parsed.deinit();
    const page = try parseChatPage(testing.allocator, parsed.value);
    defer freeChatPage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 2), page.messages.len);
    try testing.expectEqualStrings("Rita", page.messages[0].name);
    try testing.expectEqualStrings("Older two.", page.messages[1].mes);
    try testing.expect(page.messages[1].is_user);
    try testing.expectEqual(@as(usize, 42), page.total_items);
    try testing.expect(page.has_more_before);
    try testing.expectEqualStrings("v1.42.abc", page.change_token);
}

test "parseChatPage degrades a non-object or empty envelope to nothing to add" {
    const empty = try parseJson(std.json.Value, testing.allocator, "{\"messages\":[],\"total_items\":0,\"change_token\":\"v1.0.0\"}");
    defer empty.deinit();
    const p0 = try parseChatPage(testing.allocator, empty.value);
    defer freeChatPage(testing.allocator, p0);
    try testing.expectEqual(@as(usize, 0), p0.messages.len);
    try testing.expect(!p0.has_more_before);

    const bad = try parseJson(std.json.Value, testing.allocator, "42");
    defer bad.deinit();
    const p1 = try parseChatPage(testing.allocator, bad.value);
    defer freeChatPage(testing.allocator, p1);
    try testing.expectEqual(@as(usize, 0), p1.messages.len);
    try testing.expectEqualStrings("", p1.change_token);
}

test "parseChatPage cleans up on every allocation failure" {
    const parsed = try parseJson(std.json.Value, testing.allocator,
        \\{"messages":[{"name":"A","mes":"m"},{"name":"B","mes":"n"}],"change_token":"v1.2.z","total_items":2,"has_more_before":true}
    );
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, v: std.json.Value) !void {
            const page = try parseChatPage(alloc, v);
            freeChatPage(alloc, page);
        }
    }.run, .{parsed.value});
}

test "renderGreeting substitutes every macro occurrence" {
    const out = try renderGreeting(testing.allocator, "{{char}} bows. {{user}}, {{char}} waits for {{user}}.", "Rita", "Jamie");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita bows. Jamie, Rita waits for Jamie.", out);
}

test "renderGreeting cleans up on every allocation failure" {
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            const out = try renderGreeting(alloc, "{{char}}/{{user}}", "a", "b");
            alloc.free(out);
        }
    }.run, .{});
}

test "mostRecentIndex picks the max and keeps the first on ties" {
    const mk = struct {
        fn c(last: u64) Character {
            return .{
                .name = "",
                .avatar = "",
                .description = "",
                .personality = "",
                .first_mes = "",
                .scenario = "",
                .mes_example = "",
                .chat = "",
                .fav = false,
                .tags = &.{},
                .date_last_chat = last,
            };
        }
    };
    const chars = [_]Character{ mk.c(5), mk.c(9), mk.c(9), mk.c(1) };
    try testing.expectEqual(@as(?usize, 1), mostRecentIndex(&chars));
    try testing.expectEqual(@as(?usize, null), mostRecentIndex(&.{}));
}

test "encodeUriComponent keeps the unreserved set and encodes the rest" {
    const out = try encodeUriComponent(testing.allocator, "a b/c?.png!~*'()");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a%20b%2Fc%3F.png!~*'()", out);
    const utf8 = try encodeUriComponent(testing.allocator, "\xc3\xa4");
    defer testing.allocator.free(utf8);
    try testing.expectEqualStrings("%C3%A4", utf8);
}

test "thumbUrl builds the relative thumbnail path with the encoded file" {
    const out = try thumbUrl(testing.allocator, "avatar", "a b.png");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("../thumbnail?type=avatar&file=a%20b.png", out);
}

test "isoDateFromMs formats UTC dates and degrades to the epoch" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", isoDateFromMs(0, &buf));
    try testing.expectEqualStrings("1970-01-02", isoDateFromMs(86400000, &buf));
    try testing.expectEqualStrings("2026-07-11", isoDateFromMs(1783800000000, &buf));
    try testing.expectEqualStrings("2100-01-01", isoDateFromMs(4102444800000, &buf));
    try testing.expectEqualStrings("1970-01-01", isoDateFromMs(std.math.nan(f64), &buf));
}

test "chatMessages reads is_system so a narrator turn is not the character speaking" {
    const body =
        \\[{"user_name":"You"},
        \\ {"name":"Rita","is_user":false,"mes":"Hello."},
        \\ {"name":"Rita","is_user":false,"is_system":true,"mes":"The lamp dies."},
        \\ {"name":"You","is_user":true,"mes":"Hi."}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const msgs = try chatMessages(testing.allocator, parsed.value);
    defer freeChatMessages(testing.allocator, msgs);
    try testing.expectEqual(@as(usize, 3), msgs.len);
    try testing.expect(!msgs[0].is_system);
    try testing.expect(msgs[1].is_system);
    try testing.expect(!msgs[1].is_user);
    try testing.expect(!msgs[2].is_system);
}

test "parseChatPage reads is_system and the chat metadata off the header" {
    const body =
        \\{"messages":[{"name":"Rita","is_user":false,"mes":"Hello."},
        \\ {"name":"Rita","is_system":true,"mes":"Dark."}],
        \\ "header":{"user_name":"You","chat_metadata":{"note_prompt":"It is raining.","note_depth":2}},
        \\ "total_items":2,"has_more_before":false,"change_token":"v1.2.abc"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const page = try parseChatPage(testing.allocator, parsed.value);
    defer freeChatPage(testing.allocator, page);
    try testing.expect(!page.messages[0].is_system);
    try testing.expect(page.messages[1].is_system);
    try testing.expect(std.mem.indexOf(u8, page.chat_metadata, "It is raining.") != null);

    // The metadata string must outlive the response arena it was mined from, so it re-parses alone.
    const meta = try std.json.parseFromSlice(std.json.Value, testing.allocator, page.chat_metadata, .{});
    defer meta.deinit();
    try testing.expectEqualStrings("It is raining.", meta.value.object.get("note_prompt").?.string);
    try testing.expectEqual(@as(i64, 2), meta.value.object.get("note_depth").?.integer);
}

test "parseChatPage degrades a missing or hostile header to empty metadata" {
    const cases = [_][]const u8{
        \\{"messages":[],"total_items":0}
        ,
        \\{"messages":[],"header":"nope"}
        ,
        \\{"messages":[],"header":{"chat_metadata":42}}
        ,
        \\{"messages":[],"header":{}}
    };
    for (cases) |body| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
        defer parsed.deinit();
        const page = try parseChatPage(testing.allocator, parsed.value);
        defer freeChatPage(testing.allocator, page);
        try testing.expectEqualStrings("", page.chat_metadata);
    }
}

test "parseChatPage with metadata cleans up on every allocation failure" {
    const body =
        \\{"messages":[{"name":"Rita","is_user":false,"mes":"Hello."}],
        \\ "header":{"chat_metadata":{"note_prompt":"n"}},"total_items":1,"change_token":"t"}
    ;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, s: []const u8) !void {
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
            defer parsed.deinit();
            const page = try parseChatPage(alloc, parsed.value);
            freeChatPage(alloc, page);
        }
    }.run, .{@as([]const u8, body)});
}

test "tagsAlloc keeps string entries and drops hostile shapes" {
    const body =
        \\["fantasy", 42, "", {"x":1}, "slice-of-life", null]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const tags = try tagsAlloc(testing.allocator, parsed.value);
    defer freeTags(testing.allocator, tags);
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("fantasy", tags[0]);
    try testing.expectEqualStrings("slice-of-life", tags[1]);
}

test "tagsAlloc degrades every non-array shape to no tags" {
    const cases = [_][]const u8{ "\"a, b\"", "42", "{\"t\":1}", "null", "[]", "[42, null]" };
    for (cases) |body| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
        defer parsed.deinit();
        const tags = try tagsAlloc(testing.allocator, parsed.value);
        defer freeTags(testing.allocator, tags);
        try testing.expectEqual(@as(usize, 0), tags.len);
    }
}

test "tagsAlloc cleans up on every allocation failure" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\["a", "b", "c"]
    , .{});
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, v: std.json.Value) !void {
            const tags = try tagsAlloc(alloc, v);
            freeTags(alloc, tags);
        }
    }.run, .{parsed.value});
}

test "chatMessages lifts extra.reasoning and degrades hostile shapes to empty" {
    const body =
        \\[{"chat_metadata":{}},
        \\ {"name":"Rita","mes":"Answer.","extra":{"reasoning":"I should consider the shoals."}},
        \\ {"name":"Rita","mes":"No extra."},
        \\ {"name":"Rita","mes":"Bad extra.","extra":7},
        \\ {"name":"Rita","mes":"Bad reasoning.","extra":{"reasoning":42}}]
    ;
    const parsed = try parseJson(std.json.Value, testing.allocator, body);
    defer parsed.deinit();
    const msgs = try chatMessages(testing.allocator, parsed.value);
    defer freeChatMessages(testing.allocator, msgs);
    try testing.expectEqual(@as(usize, 4), msgs.len);
    try testing.expectEqualStrings("I should consider the shoals.", msgs[0].reasoning);
    try testing.expectEqualStrings("", msgs[1].reasoning);
    try testing.expectEqualStrings("", msgs[2].reasoning);
    try testing.expectEqualStrings("", msgs[3].reasoning);
}

test "parseChatPage window messages carry extra.reasoning" {
    const body =
        \\{"messages":[{"name":"Rita","mes":"Older.","extra":{"reasoning":"earlier thoughts"}}],
        \\ "change_token":"v1","has_more_before":false,"total_items":1}
    ;
    const parsed = try parseJson(std.json.Value, testing.allocator, body);
    defer parsed.deinit();
    const page = try parseChatPage(testing.allocator, parsed.value);
    defer freeChatPage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 1), page.messages.len);
    try testing.expectEqualStrings("earlier thoughts", page.messages[0].reasoning);
}

test "chatMessages with reasoning cleans up on every allocation failure" {
    const parsed = try parseJson(std.json.Value, testing.allocator, "[{},{\"name\":\"A\",\"mes\":\"m\",\"extra\":{\"reasoning\":\"r\"}}]");
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, v: std.json.Value) !void {
            const msgs = try chatMessages(alloc, v);
            freeChatMessages(alloc, msgs);
        }
    }.run, .{parsed.value});
}

// w3-chatref: the ref-agnostic page-body contract the reader and the send window ride.

test "pageBody solo tail body carries exactly the four page keys" {
    const out = try pageBody(testing.allocator, .{ .solo = .{ .avatar = "a.png", .file = "f" } }, .{ .limit = 50 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"avatar_url\":\"a.png\",\"file_name\":\"f\",\"paged\":true,\"limit\":50}", out);
}

test "pageBody solo prepend adds before_index and change_token" {
    const out = try pageBody(testing.allocator, .{ .solo = .{ .avatar = "a.png", .file = "f" } }, .{ .limit = 100, .before_index = 120, .change_token = "v1" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"avatar_url\":\"a.png\",\"file_name\":\"f\",\"paged\":true,\"limit\":100,\"before_index\":120,\"change_token\":\"v1\"}", out);
}

test "pageBody group read addresses the group id over its own route" {
    const ref = ChatRef{ .group = .{ .id = "g1" } };
    const out = try pageBody(testing.allocator, ref, .{ .limit = 300 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"id\":\"g1\",\"paged\":true,\"limit\":300}", out);
    try testing.expectEqualStrings("/api/chats/group/get", ref.url());
    try testing.expectEqualStrings("/api/chats/get", (ChatRef{ .solo = .{ .avatar = "a", .file = "f" } }).url());
}

test "ChatRef valid requires both solo parts or a group id" {
    try testing.expect((ChatRef{ .solo = .{ .avatar = "a", .file = "f" } }).valid());
    try testing.expect(!(ChatRef{ .solo = .{ .avatar = "a", .file = "" } }).valid());
    try testing.expect(!(ChatRef{ .solo = .{ .avatar = "", .file = "f" } }).valid());
    try testing.expect((ChatRef{ .group = .{ .id = "g" } }).valid());
    try testing.expect(!(ChatRef{ .group = .{ .id = "" } }).valid());
}

test "pageBody cleans up on every allocation failure" {
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            const out = try pageBody(alloc, .{ .group = .{ .id = "g1" } }, .{ .limit = 10, .before_index = 5, .change_token = "t" });
            alloc.free(out);
        }
    }.run, .{});
}
