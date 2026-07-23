//! Timestamp parsing and recency phrasing. zx-free so it joins the native `zig build test`
//! aggregator (ZX5), which is the point: the browser gate can reach today's ISO timestamps, but the
//! legacy and numeric shapes below only ever appear in a real user's older data.
//!
//! WHY THIS IS ZIG AND NOT `Date.parse`: jsz resolves a property by walking a js VALUE, and a static
//! hanging off a function object does not resolve, so `Date.parse(...)` and `Date.now()` both answer
//! error.InvalidType. Reading the clock has a way out (`performance` is a plain object, so
//! performance.timeOrigin + performance.now() is the same instant); parsing does not. So parsing
//! happens here.
//!
//! THE THREE SHAPES /api/chats/recent really sends as `last_mes` (typed {number|string} at
//! src/endpoints/chats.js:369,380):
//!   1. ISO 8601   `2026-07-14T12:30:00.000Z`  - every modern chat (chats.js:403 send_date, and the
//!      send_date writers at :147,157,188,220 are all toISOString()).
//!   2. humanized  `2026-07-14@12h30m00s000ms` - SillyTavern's own format (src/util.js:538
//!      humanizedDateTime), carried by legacy chat files' send_date.
//!   3. a bare NUMBER (epoch ms) - the empty-chat path (chats.js:450 `last_mes: stats.mtimeMs`).
//! Anything else must fail to parse, so the caller can say "recently" rather than invent a date.

const std = @import("std");

/// Epoch milliseconds for a timestamp string, or null when it is not one of the shapes above.
/// A wrong date is worse than no date, so every field is range-checked and a trailing surprise
/// rejects the whole string.
pub fn parseTimestampMs(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    if (parseIso(s)) |ms| return ms;
    if (parseHumanized(s)) |ms| return ms;
    return parseEpochDigits(s);
}

/// Epoch milliseconds for a `last_mes` straight off the JSON, which is a string on one path and a
/// number on another. Neither the client nor the server gets to pick; both arrive in real data.
pub fn timestampMsFromJson(v: std.json.Value) ?f64 {
    return switch (v) {
        .string => |s| parseTimestampMs(s),
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| parseEpochDigits(s),
        else => null,
    };
}

/// A recency phrase for `then_ms` relative to `now_ms`, written into `buf`. Past a week an exact date
/// carries more than a widening "34d ago", so it switches to the ISO date. A future or non-finite
/// stamp degrades to "recently": a clock skew must not print "in -3h".
pub fn relativeText(buf: *[32]u8, then_ms: f64, now_ms: f64) []const u8 {
    const diff = now_ms - then_ms;
    if (!std.math.isFinite(diff) or diff < 0) return "recently";
    const secs: u64 = @intFromFloat(@trunc(diff / 1000.0));
    if (secs < 60) return "just now";
    const mins = secs / 60;
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{mins}) catch "recently";
    const hours = mins / 60;
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "recently";
    const days = hours / 24;
    if (days < 7) return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "recently";
    var date_buf: [10]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}", .{isoDate(then_ms, &date_buf)}) catch "recently";
}

/// UTC calendar date (YYYY-MM-DD) for an epoch-ms stamp; non-finite or negative degrades to the epoch.
pub fn isoDate(ms: f64, buf: *[10]u8) []const u8 {
    var secs: u64 = 0;
    if (std.math.isFinite(ms) and ms > 0) secs = @intFromFloat(@trunc(ms / 1000.0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    }) catch "1970-01-01";
}

// ---- shape parsers ---------------------------------------------------------------------------

const Fields = struct {
    year: i64,
    month: u32,
    day: u32,
    hour: u32 = 0,
    minute: u32 = 0,
    second: u32 = 0,
    milli: u32 = 0,
};

/// `2026-07-14T12:30:00.000Z`. The fractional part and the zone are both optional, and a numeric
/// zone offset is applied. A zone-less ISO stamp is read as UTC, which is what the writers emit.
fn parseIso(s: []const u8) ?f64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    if (s[10] != 'T' and s[10] != ' ') return null;
    if (s[13] != ':' or s[16] != ':') return null;

    var f: Fields = .{
        .year = @intCast(digits(s[0..4]) orelse return null),
        .month = @intCast(digits(s[5..7]) orelse return null),
        .day = @intCast(digits(s[8..10]) orelse return null),
        .hour = @intCast(digits(s[11..13]) orelse return null),
        .minute = @intCast(digits(s[14..16]) orelse return null),
        .second = @intCast(digits(s[17..19]) orelse return null),
    };

    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        const frac = s[start..i];
        if (frac.len == 0) return null;
        // Any precision: the first three digits are the milliseconds, the rest is finer than we show.
        const take = @min(frac.len, 3);
        var ms: u32 = @intCast(digits(frac[0..take]) orelse return null);
        var k: usize = take;
        while (k < 3) : (k += 1) ms *= 10;
        f.milli = ms;
    }

    var offset_ms: f64 = 0;
    if (i < s.len) {
        switch (s[i]) {
            'Z', 'z' => i += 1,
            '+', '-' => {
                if (i + 6 > s.len or s[i + 3] != ':') return null;
                const oh = digits(s[i + 1 .. i + 3]) orelse return null;
                const om = digits(s[i + 4 .. i + 6]) orelse return null;
                if (oh > 23 or om > 59) return null;
                const mag: f64 = @floatFromInt((oh * 60 + om) * 60 * 1000);
                offset_ms = if (s[i] == '+') -mag else mag;
                i += 6;
            },
            else => return null,
        }
    }
    if (i != s.len) return null;

    const base = fieldsToMs(f) orelse return null;
    return base + offset_ms;
}

/// `2026-07-14@12h30m00s000ms` (src/util.js:538). Written from the SERVER's LOCAL clock with no zone,
/// so it is read as UTC: the client cannot know the writing machine's offset, and jsz cannot reach
/// the browser's own (getTimezoneOffset lives on a Date INSTANCE). Cost is bounded and legacy-only:
/// these stamps come off old chat files, which are almost always past the 7-day cutoff where the
/// phrase is already an exact date, and the skew moves that date only for a write near midnight.
fn parseHumanized(s: []const u8) ?f64 {
    if (s.len != 25) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != '@') return null;
    if (s[13] != 'h' or s[16] != 'm' or s[19] != 's' or s[23] != 'm' or s[24] != 's') return null;

    const f: Fields = .{
        .year = @intCast(digits(s[0..4]) orelse return null),
        .month = @intCast(digits(s[5..7]) orelse return null),
        .day = @intCast(digits(s[8..10]) orelse return null),
        .hour = @intCast(digits(s[11..13]) orelse return null),
        .minute = @intCast(digits(s[14..16]) orelse return null),
        .second = @intCast(digits(s[17..19]) orelse return null),
        .milli = @intCast(digits(s[20..23]) orelse return null),
    };
    return fieldsToMs(f);
}

/// An all-digit epoch-ms string. At least 10 digits are required so a bare year ("2026") cannot pass
/// as a timestamp two seconds after the epoch.
fn parseEpochDigits(s: []const u8) ?f64 {
    if (s.len < 10 or s.len > 17) return null;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const n = std.fmt.parseInt(u64, s, 10) catch return null;
    return @floatFromInt(n);
}

fn digits(s: []const u8) ?u32 {
    var out: u32 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        out = out * 10 + (c - '0');
    }
    return out;
}

fn fieldsToMs(f: Fields) ?f64 {
    if (f.month < 1 or f.month > 12) return null;
    if (f.day < 1 or f.day > 31) return null;
    if (f.hour > 23 or f.minute > 59) return null;
    // 60 is a leap second, which the epoch-day maths folds into the next minute rather than reject.
    if (f.second > 60 or f.milli > 999) return null;
    if (f.day > daysInMonth(f.year, f.month)) return null;

    const days = daysFromCivil(f.year, f.month, f.day);
    const secs = days * 86400 + @as(i64, f.hour) * 3600 + @as(i64, f.minute) * 60 + @as(i64, f.second);
    const ms = secs * 1000 + @as(i64, f.milli);
    return @floatFromInt(ms);
}

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i64, m: u32) u32 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) 29 else 28,
        else => 0,
    };
}

/// Days since 1970-01-01 for a proleptic-Gregorian date (Howard Hinnant's days_from_civil).
fn daysFromCivil(y: i64, m: u32, d: u32) i64 {
    const year = if (m <= 2) y - 1 else y;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const mp: i64 = @mod(@as(i64, m) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const testing = std.testing;

// 2026-07-14T12:30:00.000Z, per `date -u -d '2026-07-14T12:30:00Z' +%s`. Cross-checked against the
// system clock rather than this file's own maths, which is the point of an oracle: the first draft of
// this constant was wrong and the parser was right.
const ref_ms: f64 = 1784032200000;

test "parseTimestampMs reads the ISO 8601 shape the modern send_date carries" {
    try testing.expectEqual(ref_ms, parseTimestampMs("2026-07-14T12:30:00.000Z").?);
    try testing.expectEqual(ref_ms, parseTimestampMs("2026-07-14T12:30:00Z").?);
    try testing.expectEqual(ref_ms, parseTimestampMs("2026-07-14T12:30:00").?);
    try testing.expectEqual(ref_ms + 250, parseTimestampMs("2026-07-14T12:30:00.250Z").?);
    // Finer than milliseconds: the extra digits are dropped, not misread as more milliseconds.
    try testing.expectEqual(ref_ms + 250, parseTimestampMs("2026-07-14T12:30:00.250999Z").?);
}

test "parseTimestampMs applies a numeric ISO zone offset" {
    // 14:30+02:00 is the same instant as 12:30Z.
    try testing.expectEqual(ref_ms, parseTimestampMs("2026-07-14T14:30:00.000+02:00").?);
    try testing.expectEqual(ref_ms, parseTimestampMs("2026-07-14T09:30:00.000-03:00").?);
}

test "parseTimestampMs reads SillyTavern's humanized legacy shape" {
    try testing.expectEqual(ref_ms, parseTimestampMs("2026-07-14@12h30m00s000ms").?);
    try testing.expectEqual(ref_ms + 123, parseTimestampMs("2026-07-14@12h30m00s123ms").?);
}

test "parseTimestampMs reads an epoch-ms digit string" {
    try testing.expectEqual(ref_ms, parseTimestampMs("1784032200000").?);
}

test "parseTimestampMs rejects what it cannot date rather than guessing" {
    const bad = [_][]const u8{
        "", "recently", "2026", "20260714", "not-a-date",
        "2026-13-14T12:30:00Z", // month 13
        "2026-07-32T12:30:00Z", // day 32
        "2026-02-30T12:30:00Z", // 30th of February
        "2026-07-14T24:30:00Z", // hour 24
        "2026-07-14T12:60:00Z", // minute 60
        "2026-07-14T12:30:00.Z", // empty fraction
        "2026-07-14T12:30:00Q", // bogus zone
        "2026-07-14T12:30:00+0200", // offset without the colon
        "2026-07-14T12:30:00Zjunk", // trailing surprise
        "2026-07-14@12h30m00s000", // humanized, truncated
        "2026-07-14x12h30m00s000ms", // humanized, wrong separator
        "12345", // too few digits to be epoch ms
    };
    for (bad) |s| {
        try testing.expectEqual(@as(?f64, null), parseTimestampMs(s));
    }
}

test "parseTimestampMs agrees across the three shapes for one instant" {
    const iso = parseTimestampMs("2026-07-14T12:30:00.000Z").?;
    const humanized = parseTimestampMs("2026-07-14@12h30m00s000ms").?;
    const digits_form = parseTimestampMs("1784032200000").?;
    try testing.expectEqual(iso, humanized);
    try testing.expectEqual(iso, digits_form);
}

test "parseTimestampMs handles leap days and year boundaries" {
    // 2024-02-29 is real, 2026-02-29 is not.
    try testing.expect(parseTimestampMs("2024-02-29T00:00:00Z") != null);
    try testing.expectEqual(@as(?f64, null), parseTimestampMs("2026-02-29T00:00:00Z"));
    try testing.expectEqual(@as(f64, 0), parseTimestampMs("1970-01-01T00:00:00.000Z").?);
    try testing.expectEqual(@as(f64, 946684800000), parseTimestampMs("2000-01-01T00:00:00.000Z").?);
}

test "timestampMsFromJson takes the number the empty-chat path sends" {
    try testing.expectEqual(ref_ms, timestampMsFromJson(.{ .integer = 1784032200000 }).?);
    try testing.expectEqual(ref_ms, timestampMsFromJson(.{ .float = 1784032200000.0 }).?);
    try testing.expectEqual(ref_ms, timestampMsFromJson(.{ .string = "2026-07-14T12:30:00.000Z" }).?);
    try testing.expectEqual(ref_ms, timestampMsFromJson(.{ .number_string = "1784032200000" }).?);
    try testing.expectEqual(@as(?f64, null), timestampMsFromJson(.null));
    try testing.expectEqual(@as(?f64, null), timestampMsFromJson(.{ .bool = true }));
    try testing.expectEqual(@as(?f64, null), timestampMsFromJson(.{ .string = "nonsense" }));
}

test "timestampMsFromJson survives the real recent-list json, numbers and strings mixed" {
    const body =
        \\[{"last_mes":"2026-07-14T12:30:00.000Z"},{"last_mes":1784032200000},{"last_mes":"2026-07-14@12h30m00s000ms"}]
    ;
    const Row = struct { last_mes: std.json.Value = .null };
    const parsed = try std.json.parseFromSlice([]Row, testing.allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.len);
    for (parsed.value) |row| {
        try testing.expectEqual(ref_ms, timestampMsFromJson(row.last_mes).?);
    }
}

test "relativeText steps from seconds to a dated fallback" {
    var buf: [32]u8 = undefined;
    const now: f64 = ref_ms;
    try testing.expectEqualStrings("just now", relativeText(&buf, now - 30_000, now));
    try testing.expectEqualStrings("5m ago", relativeText(&buf, now - 5 * 60_000, now));
    try testing.expectEqualStrings("3h ago", relativeText(&buf, now - 3 * 3600_000, now));
    try testing.expectEqualStrings("4d ago", relativeText(&buf, now - 4 * 86400_000, now));
    // Past a week it dates the event instead of counting up forever.
    try testing.expectEqualStrings("2026-06-14", relativeText(&buf, now - 30 * 86400_000, now));
}

test "relativeText degrades a future or non-finite stamp to recently" {
    var buf: [32]u8 = undefined;
    const now: f64 = ref_ms;
    try testing.expectEqualStrings("recently", relativeText(&buf, now + 3600_000, now));
    try testing.expectEqualStrings("recently", relativeText(&buf, std.math.nan(f64), now));
    try testing.expectEqualStrings("recently", relativeText(&buf, now, std.math.nan(f64)));
}

test "isoDate formats UTC dates and degrades to the epoch" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", isoDate(0, &buf));
    try testing.expectEqualStrings("2026-07-14", isoDate(ref_ms, &buf));
    try testing.expectEqualStrings("1970-01-01", isoDate(std.math.nan(f64), &buf));
    try testing.expectEqualStrings("1970-01-01", isoDate(-5, &buf));
}

test "an ISO stamp round-trips through isoDate for a span of dates" {
    var prng = std.Random.DefaultPrng.init(0x5eed_2026);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const year: i64 = 1971 + rand.intRangeAtMost(i64, 0, 78);
        const month: u32 = rand.intRangeAtMost(u32, 1, 12);
        const day: u32 = rand.intRangeAtMost(u32, 1, daysInMonth(year, month));
        var src: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&src, "{d:0>4}-{d:0>2}-{d:0>2}T00:00:00.000Z", .{ @as(u32, @intCast(year)), month, day });
        const ms = parseTimestampMs(text) orelse return error.ParseFailed;
        var out: [10]u8 = undefined;
        try testing.expectEqualStrings(text[0..10], isoDate(ms, &out));
    }
}
