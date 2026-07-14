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
pub const CharacterJson = struct {
    name: []const u8 = "",
    avatar: []const u8 = "",
    description: []const u8 = "",
    chat: []const u8 = "",
    first_mes: []const u8 = "",
    fav: std.json.Value = .null,
    create_date: []const u8 = "",
    date_last_chat: ?f64 = null,
    chat_size: ?f64 = null,
    data_size: ?f64 = null,
};

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

pub const ChatMsg = struct {
    name: []u8,
    mes: []u8,
    is_user: bool,
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
        }
        out.deinit(alloc);
    }
    for (arr.items[1..]) |item| {
        var name_src: []const u8 = "";
        var mes_src: []const u8 = "";
        var is_user = false;
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
            },
            else => {},
        }
        const name = try alloc.dupe(u8, name_src);
        errdefer alloc.free(name);
        const mes = try alloc.dupe(u8, mes_src);
        errdefer alloc.free(mes);
        try out.append(alloc, .{ .name = name, .mes = mes, .is_user = is_user });
    }
    return try out.toOwnedSlice(alloc);
}

pub fn freeChatMessages(alloc: Allocator, list: []ChatMsg) void {
    for (list) |m| {
        alloc.free(m.name);
        alloc.free(m.mes);
    }
    alloc.free(list);
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
    try testing.expectEqualStrings("Rita", parsed.value[0].name);
    try testing.expect(favTruthy(parsed.value[0].fav));
    try testing.expectEqual(@as(u64, 1783800000000), metaU64(parsed.value[0].date_last_chat));
    try testing.expectEqualStrings("", parsed.value[1].chat);
    try testing.expectEqual(@as(u64, 0), metaU64(parsed.value[1].chat_size));
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
