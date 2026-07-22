//! The 64-bit wasm/JS crossing register and its gates (HARDENING H1, defect 3).
//!
//! The glue once passed plain JS Numbers where `bridge.zig` declares u64 (69d0b9c1b): the engine
//! throws on a Number handed to a BigInt parameter, and a Number cannot carry a u64 above 2^53.
//! The register below is the sworn list of 64-bit crossings; the source gates fail the build's
//! test step whenever `bridge.zig` grows a 64-bit signature the register does not name, or the
//! glue touches a registered crossing without BigInt handling. Value round-trips ride the real
//! store and pack code (`character_store.zig`, `doorpack.zig`).

const std = @import("std");
const testing = std.testing;
const char_store = @import("./character_store.zig");

const Crossing = struct {
    export_name: []const u8,
    fn_name: []const u8,
    u64_params: u32,
    ret_64: bool,
};

/// Every 64-bit crossing declared by bridge.zig. usize params and returns are u32 on wasm32 and
/// deliberately excluded.
const crossings = [_]Crossing{
    .{ .export_name = "__st_set_character_meta", .fn_name = "setCharacterMeta", .u64_params = 3, .ret_64 = false },
};

const bridge_candidates = [_][]const u8{ "app/pages/bridge.zig", "client/app/pages/bridge.zig", "bridge.zig" };
const glue_candidates = [_][]const u8{ "glue/custom.js", "client/glue/custom.js", "../../glue/custom.js" };

fn readSource(gpa: std.mem.Allocator, io: std.Io, candidates: []const []const u8) ![]u8 {
    for (candidates) |candidate| {
        return std.Io.Dir.cwd().readFileAlloc(io, candidate, gpa, .limited(1 << 21)) catch continue;
    }
    // A gate that cannot find its source would pass vacuously, so a miss must fail loudly.
    return error.BoundarySourceNotFound;
}

fn is64BitType(t: []const u8) bool {
    return std.mem.eql(u8, t, "u64") or std.mem.eql(u8, t, "i64") or std.mem.eql(u8, t, "f64");
}

const ScannedFn = struct {
    name: []const u8,
    u64_params: u32,
    ret_64: bool,
};

/// Parse one `fn name(params) callconv(.c) ret` around the callconv at `cc`, or null when the
/// occurrence is not a function definition site.
fn scanFnAt(text: []const u8, cc: usize) ?ScannedFn {
    const close = std.mem.lastIndexOfScalar(u8, text[0..cc], ')') orelse return null;
    var depth: usize = 1;
    var i = close;
    while (depth > 0) {
        if (i == 0) return null;
        i -= 1;
        switch (text[i]) {
            ')' => depth += 1,
            '(' => depth -= 1,
            else => {},
        }
    }
    const open = i;
    var name_end = open;
    while (name_end > 0 and std.ascii.isWhitespace(text[name_end - 1])) name_end -= 1;
    var name_start = name_end;
    while (name_start > 0 and (std.ascii.isAlphanumeric(text[name_start - 1]) or text[name_start - 1] == '_')) name_start -= 1;
    if (name_start == name_end) return null;

    var u64_params: u32 = 0;
    var params = std.mem.splitScalar(u8, text[open + 1 .. close], ',');
    while (params.next()) |param| {
        const colon = std.mem.indexOfScalar(u8, param, ':') orelse continue;
        const t = std.mem.trim(u8, param[colon + 1 ..], " \t\r\n");
        if (is64BitType(t)) u64_params += 1;
    }

    const after_cc = std.mem.trimStart(u8, text[cc + "callconv(.c)".len ..], " \t\r\n");
    const ret_end = std.mem.indexOfAny(u8, after_cc, " \t\r\n{") orelse return null;
    return .{
        .name = text[name_start..name_end],
        .u64_params = u64_params,
        .ret_64 = is64BitType(after_cc[0..ret_end]),
    };
}

fn crossingFor(fn_name: []const u8) ?Crossing {
    for (crossings) |c| {
        if (std.mem.eql(u8, c.fn_name, fn_name)) return c;
    }
    return null;
}

test "every 64-bit signature in bridge.zig is named by the crossing register" {
    const gpa = testing.allocator;
    const text = try readSource(gpa, testing.io, &bridge_candidates);
    defer gpa.free(text);

    var seen: [crossings.len]bool = @splat(false);
    var found_fns: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "callconv(.c)")) |cc| {
        at = cc + 1;
        const f = scanFnAt(text, cc) orelse continue;
        found_fns += 1;
        if (f.u64_params == 0 and !f.ret_64) continue;

        // A 64-bit signature outside the register means an unregistered, untested crossing.
        const c = crossingFor(f.name) orelse {
            std.debug.print("unregistered 64-bit crossing: {s}\n", .{f.name});
            return error.UnregisteredCrossing;
        };
        try testing.expectEqual(c.u64_params, f.u64_params);
        try testing.expectEqual(c.ret_64, f.ret_64);
        for (crossings, 0..) |cr, idx| {
            if (std.mem.eql(u8, cr.fn_name, f.name)) seen[idx] = true;
        }
    }
    // Scan floor: proves the parse walked bridge.zig's real export surface (19 callconv(.c) fns
    // today), not an empty match set. Lower only on a legitimate export removal, never to hide a scan.
    try testing.expect(found_fns >= 18);
    for (crossings, seen) |c, s| {
        if (!s) {
            std.debug.print("registered crossing missing from bridge.zig: {s}\n", .{c.fn_name});
            return error.MissingRegisteredCrossing;
        }
        const needle = try std.fmt.allocPrint(gpa, "@export(&{s}, .{{ .name = \"{s}\" }})", .{ c.fn_name, c.export_name });
        defer gpa.free(needle);
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
}

test "every glue call site of a registered 64-bit crossing handles BigInt" {
    const gpa = testing.allocator;
    const text = try readSource(gpa, testing.io, &glue_candidates);
    defer gpa.free(text);

    for (crossings) |c| {
        const call = try std.fmt.allocPrint(gpa, "{s}(", .{c.export_name});
        defer gpa.free(call);

        var calls: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, call)) |pos| {
            at = pos + call.len;
            calls += 1;
            // The BigInt evidence sits in the call's own statement or the unpack lines right
            // after it; a Number-passing or Number-comparing site has none in reach.
            const region = text[pos..@min(text.len, pos + 400)];
            const has_bigint = std.mem.indexOf(u8, region, "BigInt(") != null or
                std.mem.indexOf(u8, region, "0n") != null or
                std.mem.indexOf(u8, region, ">> 32n") != null;
            if (!has_bigint) {
                std.debug.print("glue call site of {s} without BigInt handling\n", .{c.export_name});
                return error.NumberAtSixtyFourBitCrossing;
            }
        }
        // A u64-return crossing the glue never calls would make this gate vacuous; the two
        // reader crossings are live today. Param-only crossings may have zero JS callers.
        if (c.ret_64) try testing.expect(calls >= 1);
    }
}

test "the character metadata fields and setMeta parameters stay 64-bit" {
    try testing.expectEqual(u64, @FieldType(char_store.Character, "date_last_chat"));
    try testing.expectEqual(u64, @FieldType(char_store.Character, "chat_size"));
    try testing.expectEqual(u64, @FieldType(char_store.Character, "data_size"));

    const params = @typeInfo(@TypeOf(char_store.CharacterStore.setMeta)).@"fn".params;
    try testing.expectEqual(6, params.len);
    inline for (params[3..6]) |p| try testing.expectEqual(u64, p.type.?);
}

fn blankCharacter() char_store.Character {
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
    };
}

test "u64 metadata round-trips values a JS Number cannot represent" {
    var s = char_store.CharacterStore.init(testing.allocator);
    defer s.deinit();
    try s.append(blankCharacter());

    const vals = [_]u64{ (1 << 53) + 1, std.math.maxInt(u64), 0xdead_beef_cafe_f00d };
    for (vals) |v| {
        s.setMeta(0, "2026-01-01T00:00:00.000Z", v, v -% 1, v -% 2);
        const c = s.slice()[0];
        try testing.expectEqual(v, c.date_last_chat);
        try testing.expectEqual(v -% 1, c.chat_size);
        try testing.expectEqual(v -% 2, c.data_size);
    }
}
