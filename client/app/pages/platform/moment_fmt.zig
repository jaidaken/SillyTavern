//! The moment.js subset the time macros need, as pure Zig: calendar fields for an epoch stamp, the
//! moment format tokens, and `duration.humanize`. No zx, no DOM, so it joins the native
//! `zig build test` aggregator and every rule below is provable without a browser.
//!
//! The old frontend resolves `{{time}}`, `{{date}}`, `{{weekday}}`, `{{isotime}}`, `{{isodate}}`,
//! `{{datetimeformat}}`, `{{idleDuration}}` and `{{timeDiff}}` through moment.js
//! (public/scripts/macros/definitions/time-macros.js). This module is that call surface.
//!
//! THE HUMANIZE THRESHOLDS ARE MOMENT'S, READ OFF ITS SOURCE, not a summary of them
//! (node_modules/moment/src/lib/duration/humanize.js and duration/bubble.js):
//!   - every unit count is Math.round of the WHOLE duration in that unit, never a floor of a
//!     remainder, so 90 seconds is "2 minutes" and 89 is "a minute".
//!   - the ladder is seconds <= 44, minutes <= 1, minutes < 45, hours <= 1, hours < 22, days <= 1,
//!     days < 26, months <= 1, months < 11, years <= 1, else years.
//!   - months are days * 4800 / 146097 (400 Gregorian years = 146097 days = 4800 months), so the
//!     month boundary is 45.6553125 days and the year boundary is 547.86375 days, not the whole
//!     days a summary would suggest.
//! moment's `ss` branch (seconds < 45 after seconds <= 44 already failed) is unreachable at the
//! default thresholds, so it has no counterpart here.

const std = @import("std");

/// Calendar fields for one instant in one zone. weekday 0 is Sunday, matching moment's `d`.
pub const DateTime = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8,
};

/// Calendar fields for an epoch-millisecond stamp, shifted by a whole-minute UTC offset.
/// Pass 0 for UTC; `{{time::UTC+2}}` passes 120.
pub fn fromEpochMs(ms: i64, utc_offset_minutes: i32) DateTime {
    const shifted = ms + @as(i64, utc_offset_minutes) * std.time.ms_per_min;
    const secs = @divFloor(shifted, 1000);
    const days = @divFloor(secs, std.time.s_per_day);
    const sod = secs - days * std.time.s_per_day;
    const civil = civilFromDays(days);
    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = @intCast(@divFloor(sod, 3600)),
        .minute = @intCast(@divFloor(@mod(sod, 3600), 60)),
        .second = @intCast(@mod(sod, 60)),
        // 1970-01-01 was a Thursday, so day 0 is weekday 4.
        .weekday = @intCast(@mod(days + 4, 7)),
    };
}

/// Renders `dt` through a moment format string. Tokens match longest-first; `[text]` passes through
/// verbatim; anything else is a literal character.
pub fn format(alloc: std.mem.Allocator, fmt: []const u8, dt: DateTime) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try writeFormat(alloc, &out, fmt, dt);
    return out.toOwnedSlice(alloc);
}

/// moment's `duration.humanize`. `with_suffix` reads a positive duration as "in X" and a negative
/// or zero one as "X ago", the same way moment's pastFuture splits on `diff > 0`.
pub fn humanizeDuration(alloc: std.mem.Allocator, ms: i64, with_suffix: bool) std.mem.Allocator.Error![]u8 {
    const magnitude: f64 = @floatFromInt(@abs(ms));
    const raw_days = magnitude / @as(f64, std.time.ms_per_day);
    const raw_months = raw_days * 4800.0 / 146097.0;

    const seconds = round(magnitude / 1000.0);
    const minutes = round(magnitude / @as(f64, std.time.ms_per_min));
    const hours = round(magnitude / @as(f64, std.time.ms_per_hour));
    const days = round(raw_days);
    const months = round(raw_months);
    const years = round(raw_months / 12.0);

    const phrase: Phrase = if (seconds <= 44)
        .{ .text = "a few seconds" }
    else if (minutes <= 1)
        .{ .text = "a minute" }
    else if (minutes < 45)
        .{ .text = "minutes", .count = minutes }
    else if (hours <= 1)
        .{ .text = "an hour" }
    else if (hours < 22)
        .{ .text = "hours", .count = hours }
    else if (days <= 1)
        .{ .text = "a day" }
    else if (days < 26)
        .{ .text = "days", .count = days }
    else if (months <= 1)
        .{ .text = "a month" }
    else if (months < 11)
        .{ .text = "months", .count = months }
    else if (years <= 1)
        .{ .text = "a year" }
    else
        .{ .text = "years", .count = years };

    var counted: [40]u8 = undefined;
    const body: []const u8 = if (phrase.count) |n|
        std.fmt.bufPrint(&counted, "{d} {s}", .{ n, phrase.text }) catch unreachable
    else
        phrase.text;

    if (!with_suffix) return alloc.dupe(u8, body);
    if (ms > 0) return std.fmt.allocPrint(alloc, "in {s}", .{body});
    return std.fmt.allocPrint(alloc, "{s} ago", .{body});
}

const Phrase = struct { text: []const u8, count: ?i64 = null };

/// Math.round: half away from zero on the positive magnitudes humanize works with.
fn round(x: f64) i64 {
    return @intFromFloat(@floor(x + 0.5));
}

const Civil = struct { year: i32, month: u8, day: u8 };

/// Howard Hinnant's civil_from_days, the inverse of datetime.zig's daysFromCivil.
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

const Token = enum { LLLL, LLL, LL, LT, YYYY, YY, MMMM, MMM, MM, M, DDDD, dddd, ddd, DD, D, HH, H, hh, h, mm, m, ss, s, A, a };

/// Longest-first, so `MMMM` never matches as `MMM` and `LLLL` never as `LL`.
const tokens = [_]struct { text: []const u8, tok: Token }{
    .{ .text = "LLLL", .tok = .LLLL },
    .{ .text = "LLL", .tok = .LLL },
    .{ .text = "LL", .tok = .LL },
    .{ .text = "LT", .tok = .LT },
    .{ .text = "YYYY", .tok = .YYYY },
    .{ .text = "YY", .tok = .YY },
    .{ .text = "MMMM", .tok = .MMMM },
    .{ .text = "MMM", .tok = .MMM },
    .{ .text = "MM", .tok = .MM },
    .{ .text = "M", .tok = .M },
    .{ .text = "DDDD", .tok = .DDDD },
    .{ .text = "dddd", .tok = .dddd },
    .{ .text = "ddd", .tok = .ddd },
    .{ .text = "DD", .tok = .DD },
    .{ .text = "D", .tok = .D },
    .{ .text = "HH", .tok = .HH },
    .{ .text = "H", .tok = .H },
    .{ .text = "hh", .tok = .hh },
    .{ .text = "h", .tok = .h },
    .{ .text = "mm", .tok = .mm },
    .{ .text = "m", .tok = .m },
    .{ .text = "ss", .tok = .ss },
    .{ .text = "s", .tok = .s },
    .{ .text = "A", .tok = .A },
    .{ .text = "a", .tok = .a },
};

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

fn writeFormat(alloc: std.mem.Allocator, out: *std.ArrayList(u8), fmt: []const u8, dt: DateTime) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, fmt, i + 1, ']')) |end| {
                try out.appendSlice(alloc, fmt[i + 1 .. end]);
                i = end + 1;
                continue;
            }
        }
        if (matchToken(fmt[i..])) |m| {
            try writeToken(alloc, out, m.tok, dt);
            i += m.len;
            continue;
        }
        try out.append(alloc, fmt[i]);
        i += 1;
    }
}

fn matchToken(rest: []const u8) ?struct { tok: Token, len: usize } {
    for (tokens) |entry| {
        if (std.mem.startsWith(u8, rest, entry.text)) return .{ .tok = entry.tok, .len = entry.text.len };
    }
    return null;
}

fn writeToken(alloc: std.mem.Allocator, out: *std.ArrayList(u8), tok: Token, dt: DateTime) std.mem.Allocator.Error!void {
    const hour12: u32 = if (dt.hour % 12 == 0) 12 else dt.hour % 12;
    switch (tok) {
        .LT => try writeFormat(alloc, out, "h:mm A", dt),
        // moment's DEFAULT en locale, which is what the old frontend renders: nothing in public/ or
        // src/ ever calls moment.locale, so a card written against SillyTavern expects this order.
        .LL => try writeFormat(alloc, out, "MMMM D, YYYY", dt),
        .LLL => try writeFormat(alloc, out, "MMMM D, YYYY h:mm A", dt),
        .LLLL => try writeFormat(alloc, out, "dddd, MMMM D, YYYY h:mm A", dt),
        .YYYY => try writeYear(alloc, out, dt.year, 4),
        .YY => try writeYear(alloc, out, @mod(dt.year, 100), 2),
        .MMMM => try out.appendSlice(alloc, month_names[dt.month - 1]),
        .MMM => try out.appendSlice(alloc, month_names[dt.month - 1][0..3]),
        .MM => try writePadded(alloc, out, dt.month, 2),
        .M => try writePadded(alloc, out, dt.month, 1),
        .DDDD => try writePadded(alloc, out, dayOfYear(dt), 3),
        .dddd => try out.appendSlice(alloc, weekday_names[dt.weekday]),
        .ddd => try out.appendSlice(alloc, weekday_names[dt.weekday][0..3]),
        .DD => try writePadded(alloc, out, dt.day, 2),
        .D => try writePadded(alloc, out, dt.day, 1),
        .HH => try writePadded(alloc, out, dt.hour, 2),
        .H => try writePadded(alloc, out, dt.hour, 1),
        .hh => try writePadded(alloc, out, hour12, 2),
        .h => try writePadded(alloc, out, hour12, 1),
        .mm => try writePadded(alloc, out, dt.minute, 2),
        .m => try writePadded(alloc, out, dt.minute, 1),
        .ss => try writePadded(alloc, out, dt.second, 2),
        .s => try writePadded(alloc, out, dt.second, 1),
        .A => try out.appendSlice(alloc, if (dt.hour < 12) "AM" else "PM"),
        .a => try out.appendSlice(alloc, if (dt.hour < 12) "am" else "pm"),
    }
}

fn writePadded(alloc: std.mem.Allocator, out: *std.ArrayList(u8), value: u32, width: usize) std.mem.Allocator.Error!void {
    var buf: [12]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    var pad = width -| digits.len;
    while (pad > 0) : (pad -= 1) try out.append(alloc, '0');
    try out.appendSlice(alloc, digits);
}

fn writeYear(alloc: std.mem.Allocator, out: *std.ArrayList(u8), year: i32, width: usize) std.mem.Allocator.Error!void {
    if (year < 0) try out.append(alloc, '-');
    try writePadded(alloc, out, @abs(year), width);
}

fn dayOfYear(dt: DateTime) u32 {
    const cumulative = [_]u32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    const leap = (@mod(dt.year, 4) == 0 and @mod(dt.year, 100) != 0) or @mod(dt.year, 400) == 0;
    const bump: u32 = if (leap and dt.month > 2) 1 else 0;
    return cumulative[dt.month - 1] + dt.day + bump;
}

const t = std.testing;

// 2026-07-14T12:30:00.000Z, a Tuesday, cross-checked with `date -u -d @1784032200`.
const ref_ms: i64 = 1784032200000;

test "fromEpochMs splits an epoch stamp into UTC calendar fields" {
    const dt = fromEpochMs(ref_ms, 0);
    try t.expectEqual(@as(i32, 2026), dt.year);
    try t.expectEqual(@as(u8, 7), dt.month);
    try t.expectEqual(@as(u8, 14), dt.day);
    try t.expectEqual(@as(u8, 12), dt.hour);
    try t.expectEqual(@as(u8, 30), dt.minute);
    try t.expectEqual(@as(u8, 0), dt.second);
    try t.expectEqual(@as(u8, 2), dt.weekday);
}

test "fromEpochMs shifts by a whole-minute UTC offset in both directions" {
    const plus = fromEpochMs(ref_ms, 120);
    try t.expectEqual(@as(u8, 14), plus.hour);
    try t.expectEqual(@as(u8, 14), plus.day);
    const minus = fromEpochMs(ref_ms, -13 * 60);
    try t.expectEqual(@as(u8, 23), minus.hour);
    try t.expectEqual(@as(u8, 13), minus.day);
    try t.expectEqual(@as(u8, 1), minus.weekday);
    // Half-hour zones are why the offset is minutes and not hours.
    const half = fromEpochMs(ref_ms, 330);
    try t.expectEqual(@as(u8, 18), half.hour);
    try t.expectEqual(@as(u8, 0), half.minute);
}

test "fromEpochMs handles the epoch, leap days and pre-1970 stamps" {
    const epoch = fromEpochMs(0, 0);
    try t.expectEqual(@as(i32, 1970), epoch.year);
    try t.expectEqual(@as(u8, 1), epoch.month);
    try t.expectEqual(@as(u8, 1), epoch.day);
    try t.expectEqual(@as(u8, 4), epoch.weekday);

    const leap = fromEpochMs(1709164800000, 0);
    try t.expectEqual(@as(i32, 2024), leap.year);
    try t.expectEqual(@as(u8, 2), leap.month);
    try t.expectEqual(@as(u8, 29), leap.day);

    // 1969-07-20T20:17:00Z, the Apollo 11 landing: a negative stamp must floor, not truncate.
    const past = fromEpochMs(-14182980000, 0);
    try t.expectEqual(@as(i32, 1969), past.year);
    try t.expectEqual(@as(u8, 7), past.month);
    try t.expectEqual(@as(u8, 20), past.day);
    try t.expectEqual(@as(u8, 20), past.hour);
    try t.expectEqual(@as(u8, 17), past.minute);
}

test "format renders every numeric and name token" {
    const dt = fromEpochMs(ref_ms, 0);
    const cases = [_]struct { fmt: []const u8, want: []const u8 }{
        .{ .fmt = "YYYY-MM-DD", .want = "2026-07-14" },
        .{ .fmt = "YY", .want = "26" },
        .{ .fmt = "M/D/YY", .want = "7/14/26" },
        .{ .fmt = "MMMM", .want = "July" },
        .{ .fmt = "MMM", .want = "Jul" },
        .{ .fmt = "dddd", .want = "Tuesday" },
        .{ .fmt = "ddd", .want = "Tue" },
        .{ .fmt = "DDDD", .want = "195" },
        .{ .fmt = "HH:mm", .want = "12:30" },
        .{ .fmt = "H:m:s", .want = "12:30:0" },
        .{ .fmt = "hh:mm:ss A", .want = "12:30:00 PM" },
        .{ .fmt = "h:mm a", .want = "12:30 pm" },
    };
    for (cases) |c| {
        const got = try format(t.allocator, c.fmt, dt);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c.want, got);
    }
}

test "format expands the locale forms the macros ask for" {
    const dt = fromEpochMs(ref_ms, 0);
    const cases = [_]struct { fmt: []const u8, want: []const u8 }{
        .{ .fmt = "LT", .want = "12:30 PM" },
        .{ .fmt = "LL", .want = "July 14, 2026" },
        .{ .fmt = "LLL", .want = "July 14, 2026 12:30 PM" },
        .{ .fmt = "LLLL", .want = "Tuesday, July 14, 2026 12:30 PM" },
    };
    for (cases) |c| {
        const got = try format(t.allocator, c.fmt, dt);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c.want, got);
    }
}

test "format switches the meridiem and the twelve-hour clock around midnight and noon" {
    const midnight = fromEpochMs(1784030400000 - 12 * std.time.ms_per_hour, 0);
    const got_midnight = try format(t.allocator, "hh:mm A HH", midnight);
    defer t.allocator.free(got_midnight);
    try t.expectEqualStrings("12:00 AM 00", got_midnight);

    const one_am = fromEpochMs(1784030400000 - 11 * std.time.ms_per_hour, 0);
    const got_one = try format(t.allocator, "h:mm a", one_am);
    defer t.allocator.free(got_one);
    try t.expectEqualStrings("1:00 am", got_one);

    const noon = fromEpochMs(1784030400000, 0);
    const got_noon = try format(t.allocator, "h:mm A", noon);
    defer t.allocator.free(got_noon);
    try t.expectEqualStrings("12:00 PM", got_noon);
}

test "format passes bracketed text through and treats unknown characters as literals" {
    const dt = fromEpochMs(ref_ms, 0);
    const cases = [_]struct { fmt: []const u8, want: []const u8 }{
        // The bracket body keeps its would-be tokens: MMMM inside brackets is not a month.
        .{ .fmt = "[MMMM] MMMM", .want = "MMMM July" },
        .{ .fmt = "[on] dddd", .want = "on Tuesday" },
        .{ .fmt = "[]DD", .want = "14" },
        // An unclosed bracket is a literal bracket, as moment's token regex leaves it.
        .{ .fmt = "[DD", .want = "[14" },
        .{ .fmt = "!?*", .want = "!?*" },
        .{ .fmt = "", .want = "" },
    };
    for (cases) |c| {
        const got = try format(t.allocator, c.fmt, dt);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c.want, got);
    }
}

test "format matches the longest token first" {
    const dt = fromEpochMs(ref_ms, 0);
    // MMMM is one token, not MMM followed by M; LLLL is one token, not LL twice.
    const got = try format(t.allocator, "MMMM|LLLL", dt);
    defer t.allocator.free(got);
    try t.expectEqualStrings("July|Tuesday, July 14, 2026 12:30 PM", got);
}

test "format DDDD counts the leap day into the day of year" {
    const before = fromEpochMs(1709164800000, 0);
    const got_before = try format(t.allocator, "DDDD", before);
    defer t.allocator.free(got_before);
    try t.expectEqualStrings("060", got_before);

    const after = fromEpochMs(1709164800000 + std.time.ms_per_day, 0);
    const got_after = try format(t.allocator, "DDDD", after);
    defer t.allocator.free(got_after);
    try t.expectEqualStrings("061", got_after);
}

test "humanizeDuration walks moment's whole ladder" {
    const cases = [_]struct { ms: i64, want: []const u8 }{
        .{ .ms = 0, .want = "a few seconds" },
        .{ .ms = 44_499, .want = "a few seconds" },
        .{ .ms = 44_500, .want = "a minute" },
        .{ .ms = 89_999, .want = "a minute" },
        .{ .ms = 90_000, .want = "2 minutes" },
        .{ .ms = 2_669_999, .want = "44 minutes" },
        .{ .ms = 2_670_000, .want = "an hour" },
        .{ .ms = 5_399_999, .want = "an hour" },
        .{ .ms = 5_400_000, .want = "2 hours" },
        .{ .ms = 77_399_999, .want = "21 hours" },
        .{ .ms = 77_400_000, .want = "a day" },
        .{ .ms = 129_599_999, .want = "a day" },
        .{ .ms = 129_600_000, .want = "2 days" },
        .{ .ms = 2_203_199_999, .want = "25 days" },
        .{ .ms = 2_203_200_000, .want = "a month" },
        // 45.6553125 days is where moment's month count rounds from 1 to 2.
        .{ .ms = 3_944_618_999, .want = "a month" },
        .{ .ms = 3_944_619_001, .want = "2 months" },
        // 319.5871875 days is where the month count reaches 11 and the year branch takes over.
        .{ .ms = 27_612_332_999, .want = "10 months" },
        .{ .ms = 27_612_333_001, .want = "a year" },
        // 547.86375 days is where the year count rounds from 1 to 2.
        .{ .ms = 47_335_427_999, .want = "a year" },
        .{ .ms = 47_335_428_001, .want = "2 years" },
        .{ .ms = 10 * 365 * std.time.ms_per_day, .want = "10 years" },
    };
    for (cases) |c| {
        const got = try humanizeDuration(t.allocator, c.ms, false);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c.want, got);
    }
}

test "humanizeDuration reads the sign as a suffix and measures a negative span by its magnitude" {
    const cases = [_]struct { ms: i64, want: []const u8 }{
        .{ .ms = 3 * std.time.ms_per_hour, .want = "in 3 hours" },
        .{ .ms = -3 * std.time.ms_per_hour, .want = "3 hours ago" },
        .{ .ms = 5 * std.time.ms_per_min, .want = "in 5 minutes" },
        .{ .ms = -5 * std.time.ms_per_min, .want = "5 minutes ago" },
        .{ .ms = 0, .want = "a few seconds ago" },
        .{ .ms = -std.time.ms_per_day * 400, .want = "a year ago" },
    };
    for (cases) |c| {
        const got = try humanizeDuration(t.allocator, c.ms, true);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c.want, got);
    }
}

test "humanizeDuration is symmetric about zero" {
    var prng = std.Random.DefaultPrng.init(0x7_1_e_2026);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const ms = rand.intRangeAtMost(i64, 1, 4 * 365 * std.time.ms_per_day);
        const forward = try humanizeDuration(t.allocator, ms, false);
        defer t.allocator.free(forward);
        const backward = try humanizeDuration(t.allocator, -ms, false);
        defer t.allocator.free(backward);
        try t.expectEqualStrings(forward, backward);
    }
}

test "format round-trips a rendered ISO stamp back through fromEpochMs" {
    var prng = std.Random.DefaultPrng.init(0x5eed_71_e);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const ms = rand.intRangeAtMost(i64, -2_000_000_000_000, 4_000_000_000_000);
        const dt = fromEpochMs(ms, 0);
        const text = try format(t.allocator, "YYYY-MM-DDTHH:mm:ss", dt);
        defer t.allocator.free(text);
        const seconds_ms = @divFloor(ms, 1000) * 1000;
        const again = fromEpochMs(seconds_ms, 0);
        const text_again = try format(t.allocator, "YYYY-MM-DDTHH:mm:ss", again);
        defer t.allocator.free(text_again);
        try t.expectEqualStrings(text, text_again);
        try t.expectEqual(@as(usize, 19), text.len);
    }
}

fn formatProbe(alloc: std.mem.Allocator) !void {
    const dt = fromEpochMs(ref_ms, 90);
    const long = try format(alloc, "LLLL [at] YYYY-MM-DD HH:mm:ss A dddd DDDD", dt);
    alloc.free(long);
    const short = try format(alloc, "LT", dt);
    alloc.free(short);
}

test "format releases every allocation on injected failure" {
    try t.checkAllAllocationFailures(t.allocator, formatProbe, .{});
}

fn humanizeProbe(alloc: std.mem.Allocator) !void {
    const counted = try humanizeDuration(alloc, -9 * std.time.ms_per_hour, true);
    alloc.free(counted);
    const bare = try humanizeDuration(alloc, 30 * std.time.ms_per_day, false);
    alloc.free(bare);
}

test "humanizeDuration releases every allocation on injected failure" {
    try t.checkAllAllocationFailures(t.allocator, humanizeProbe, .{});
}
