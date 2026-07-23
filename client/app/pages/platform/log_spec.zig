//! The `st_log` category spec, parsed. Format is the server's ST_LOG format, the one the JS
//! logger already used: `cat:level,cat:level` (for example `chars:debug,net:warn`), read once at
//! boot from localStorage. Zig holds the thresholds so a below-threshold message is dropped
//! BEFORE it crosses the wasm boundary: no formatting, no string copy, no JS call.
//!
//! Pure: no zx, no extern, so `zig build test` proves the parse. log.zig owns the live instance.

const std = @import("std");

/// Ordered so a message prints when its own level ranks at or above the category threshold.
/// Values match the JS logger's table, and `silent` sits above every message level.
pub const Level = enum(i8) {
    trace = -1,
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    silent = 100,
};

/// Categories with no entry in the spec print info and above, matching the JS default.
pub const default_level: Level = .info;

const max_entries = 16;
const max_name = 24;

pub const Thresholds = struct {
    names: [max_entries][max_name]u8 = @splat(@splat(0)),
    lens: [max_entries]u8 = @splat(0),
    levels: [max_entries]Level = @splat(default_level),
    count: usize = 0,

    pub fn thresholdFor(self: Thresholds, category: []const u8) Level {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.names[i][0..self.lens[i]], category)) return self.levels[i];
        }
        return default_level;
    }

    /// True when a message of `level` in `category` should reach the console.
    pub fn enabled(self: Thresholds, category: []const u8, level: std.log.Level) bool {
        return @intFromEnum(levelOf(level)) >= @intFromEnum(self.thresholdFor(category));
    }
};

pub fn levelOf(level: std.log.Level) Level {
    return switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
}

/// Level names are matched case-insensitively, as in the JS logger; an unknown name is ignored
/// (the category keeps the default) rather than silencing it.
pub fn parseLevel(text: []const u8) ?Level {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0 or trimmed.len > 8) return null;
    var buf: [8]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..trimmed.len], trimmed);
    inline for (@typeInfo(Level).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, lower)) return @field(Level, f.name);
    }
    // The JS spec writes "error"; the Zig level is `err`.
    if (std.mem.eql(u8, lower, "error")) return .err;
    return null;
}

/// Parse `cat:level,cat:level`. Junk pairs are skipped; an over-long spec keeps its first
/// `max_entries` categories, so a malformed value can never silence the log wholesale.
pub fn parse(raw: []const u8) Thresholds {
    var out: Thresholds = .{};
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        if (out.count == max_entries) break;
        var bits = std.mem.splitScalar(u8, part, ':');
        const name = std.mem.trim(u8, bits.first(), " \t");
        const level_text = bits.next() orelse continue;
        if (name.len == 0 or name.len > max_name) continue;
        const level = parseLevel(level_text) orelse continue;
        const i = out.count;
        @memcpy(out.names[i][0..name.len], name);
        out.lens[i] = @intCast(name.len);
        out.levels[i] = level;
        out.count += 1;
    }
    return out;
}

const testing = std.testing;

test "an empty spec leaves every category at the info default" {
    const t = parse("");
    try testing.expectEqual(@as(usize, 0), t.count);
    try testing.expectEqual(default_level, t.thresholdFor("chars"));
    try testing.expect(t.enabled("chars", .info));
    try testing.expect(t.enabled("chars", .err));
    try testing.expect(!t.enabled("chars", .debug));
}

test "per-category thresholds apply only to their own category" {
    const t = parse("chars:debug,net:warn");
    try testing.expectEqual(@as(usize, 2), t.count);
    try testing.expect(t.enabled("chars", .debug));
    try testing.expect(!t.enabled("net", .info));
    try testing.expect(t.enabled("net", .warn));
    // An unlisted category keeps the default.
    try testing.expect(!t.enabled("panels", .debug));
    try testing.expect(t.enabled("panels", .info));
}

test "level names are case-insensitive and error maps to err" {
    try testing.expectEqual(Level.err, parseLevel("ERROR").?);
    try testing.expectEqual(Level.err, parseLevel("err").?);
    try testing.expectEqual(Level.silent, parseLevel("Silent").?);
    try testing.expect(parseLevel("nonesuch") == null);
    const t = parse(" chars : SILENT ");
    try testing.expect(!t.enabled("chars", .err));
}

test "junk pairs are skipped without disturbing the valid ones" {
    const t = parse("chars,net:bogus,,panels:debug,:info");
    try testing.expectEqual(@as(usize, 1), t.count);
    try testing.expect(t.enabled("panels", .debug));
    try testing.expectEqual(default_level, t.thresholdFor("net"));
    try testing.expectEqual(default_level, t.thresholdFor("chars"));
}

test "an over-long spec keeps its first entries instead of silencing everything" {
    const t = parse("a:debug,b:debug,c:debug,d:debug,e:debug,f:debug,g:debug,h:debug," ++
        "i:debug,j:debug,k:debug,l:debug,m:debug,n:debug,o:debug,p:debug,q:debug,r:debug");
    try testing.expectEqual(@as(usize, 16), t.count);
    try testing.expect(t.enabled("a", .debug));
    try testing.expect(!t.enabled("r", .debug));
    try testing.expect(t.enabled("r", .info));
}
