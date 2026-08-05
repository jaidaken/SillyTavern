//! The time macros, over the moment subset in platform/moment_fmt.zig. Stock resolves these through
//! moment.js (public/scripts/macros/definitions/time-macros.js): `{{time}}` is moment().format('LT'),
//! `{{date}}` is 'LL', `{{weekday}}` is 'dddd', and the iso pair are the fixed HH:mm / YYYY-MM-DD.
//!
//! A zero `now_ms` means the caller could not read a clock, and every macro then declines (returns
//! null) so the literal survives instead of the prompt claiming it is 1 January 1970.

const std = @import("std");

const moment = @import("../platform/moment_fmt.zig");

const Allocator = std.mem.Allocator;

/// The clock a resolution reads. `idle_ms` is the gap since the last user message, for
/// `{{idleDuration}}`; the offset is minutes east of UTC, since the caller owns the timezone.
pub const Clock = struct {
    now_ms: i64 = 0,
    utc_offset_minutes: i32 = 0,
    idle_ms: i64 = 0,
};

/// Resolves one time macro body (no braces, `::` arguments intact). Returns an owned string the
/// caller frees, or null when `inner` names no time macro or no clock was supplied.
pub fn resolve(alloc: Allocator, inner: []const u8, clock: Clock) Allocator.Error!?[]u8 {
    if (clock.now_ms == 0) return null;
    const name = std.mem.trim(u8, if (std.mem.indexOf(u8, inner, "::")) |c| inner[0..c] else inner, " \t");
    const arg: []const u8 = if (std.mem.indexOf(u8, inner, "::")) |c| std.mem.trim(u8, inner[c + 2 ..], " \t") else "";

    if (std.mem.eql(u8, name, "time")) {
        // {{time::UTC+2}} re-bases the clock; anything that is not that exact shape falls back to local.
        const offset = parseUtcOffset(arg) orelse clock.utc_offset_minutes;
        return try moment.format(alloc, "LT", moment.fromEpochMs(clock.now_ms, offset));
    }
    if (std.mem.eql(u8, name, "date")) return try fmtLocal(alloc, "LL", clock);
    if (std.mem.eql(u8, name, "weekday")) return try fmtLocal(alloc, "dddd", clock);
    if (std.mem.eql(u8, name, "isotime")) return try fmtLocal(alloc, "HH:mm", clock);
    if (std.mem.eql(u8, name, "isodate")) return try fmtLocal(alloc, "YYYY-MM-DD", clock);
    if (std.mem.eql(u8, name, "datetimeformat")) {
        if (arg.len == 0) return try alloc.dupe(u8, "");
        return try fmtLocal(alloc, arg, clock);
    }
    if (std.mem.eql(u8, name, "timeDiff")) {
        // Stock takes moment(left).diff(moment(right)) and humanizes it with a suffix, so the order of
        // the pair decides "in X" versus "X ago"; an unparseable side leaves the literal alone.
        const sep = std.mem.indexOf(u8, arg, "::") orelse return null;
        const left = parseWhen(std.mem.trim(u8, arg[0..sep], " \t"), clock) orelse return null;
        const right = parseWhen(std.mem.trim(u8, arg[sep + 2 ..], " \t"), clock) orelse return null;
        return try moment.humanizeDuration(alloc, left - right, true);
    }
    if (std.mem.eql(u8, name, "idleDuration") or std.mem.eql(u8, name, "idle_duration")) {
        // Stock reads the gap as a past duration, so the suffix side is "ago".
        return try moment.humanizeDuration(alloc, -clock.idle_ms, true);
    }
    return null;
}

/// Epoch ms for a `{{timeDiff}}` operand. Accepts "now" and the two shapes a card realistically
/// writes: `YYYY-MM-DD` and `YYYY-MM-DD HH:MM[:SS]`, read as UTC like moment reads a bare ISO string.
/// Null for anything else, which leaves the macro unresolved rather than inventing an instant.
fn parseWhen(text: []const u8, clock: Clock) ?i64 {
    if (text.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(text, "now")) return clock.now_ms;
    if (text.len < 10) return null;
    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    if (text[4] != '-' or text[7] != '-') return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    var hour: u8 = 0;
    var minute: u8 = 0;
    var second: u8 = 0;
    if (text.len >= 16) {
        hour = std.fmt.parseInt(u8, text[11..13], 10) catch return null;
        minute = std.fmt.parseInt(u8, text[14..16], 10) catch return null;
        if (text.len >= 19) second = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
    }
    const days = daysFromCivil(year, month, day);
    return (days * std.time.ms_per_day) +
        (@as(i64, hour) * std.time.ms_per_hour) +
        (@as(i64, minute) * std.time.ms_per_min) +
        (@as(i64, second) * std.time.ms_per_s);
}

/// Days since the epoch for a civil date (Howard Hinnant's days_from_civil).
fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn fmtLocal(alloc: Allocator, fmt: []const u8, clock: Clock) Allocator.Error![]u8 {
    return moment.format(alloc, fmt, moment.fromEpochMs(clock.now_ms, clock.utc_offset_minutes));
}

/// Minutes east of UTC for a `UTC+2` / `UTC-7` argument, or null for anything else (stock's regex is
/// anchored and whole-hour only, and a miss there falls back to local time rather than erroring).
fn parseUtcOffset(arg: []const u8) ?i32 {
    if (arg.len < 4) return null;
    if (!std.mem.startsWith(u8, arg, "UTC")) return null;
    const rest = arg[3..];
    if (rest[0] != '+' and rest[0] != '-') return null;
    const hours = std.fmt.parseInt(i32, rest[1..], 10) catch return null;
    const signed: i32 = if (rest[0] == '-') -hours else hours;
    return signed * 60;
}

const t = std.testing;

/// 2026-07-14T12:30:00Z, a Tuesday, so a weekday assertion cannot pass by accident.
const ref_ms: i64 = 1784032200000;

test "resolve renders the clock macros the old frontend formats with moment" {
    const clock = Clock{ .now_ms = ref_ms };
    const cases = [_]struct { inner: []const u8, want: []const u8 }{
        .{ .inner = "time", .want = "12:30 PM" },
        .{ .inner = "date", .want = "July 14, 2026" },
        .{ .inner = "weekday", .want = "Tuesday" },
        .{ .inner = "isotime", .want = "12:30" },
        .{ .inner = "isodate", .want = "2026-07-14" },
        .{ .inner = "datetimeformat::YYYY/MM/DD", .want = "2026/07/14" },
    };
    for (cases) |c| {
        const got = (try resolve(t.allocator, c.inner, clock)).?;
        defer t.allocator.free(got);
        try t.expectEqualStrings(c.want, got);
    }
}

test "time takes a whole-hour UTC offset and ignores a malformed one" {
    const clock = Clock{ .now_ms = ref_ms, .utc_offset_minutes = 0 };
    const shifted = (try resolve(t.allocator, "time::UTC+2", clock)).?;
    defer t.allocator.free(shifted);
    try t.expectEqualStrings("2:30 PM", shifted);

    const junk = (try resolve(t.allocator, "time::UTC+banana", clock)).?;
    defer t.allocator.free(junk);
    try t.expectEqualStrings("12:30 PM", junk);
}

test "idleDuration reads as a past duration and accepts the underscore alias" {
    const clock = Clock{ .now_ms = ref_ms, .idle_ms = 5 * std.time.ms_per_min };
    const got = (try resolve(t.allocator, "idleDuration", clock)).?;
    defer t.allocator.free(got);
    try t.expectEqualStrings("5 minutes ago", got);

    const alias = (try resolve(t.allocator, "idle_duration", clock)).?;
    defer t.allocator.free(alias);
    try t.expectEqualStrings("5 minutes ago", alias);
}

test "no clock declines every time macro so the literal survives" {
    const clock = Clock{ .now_ms = 0 };
    try t.expectEqual(@as(?[]u8, null), try resolve(t.allocator, "time", clock));
    try t.expectEqual(@as(?[]u8, null), try resolve(t.allocator, "isodate", clock));
}

test "a name that is not a time macro declines" {
    const clock = Clock{ .now_ms = ref_ms };
    try t.expectEqual(@as(?[]u8, null), try resolve(t.allocator, "lastMessage", clock));
    try t.expectEqual(@as(?[]u8, null), try resolve(t.allocator, "char", clock));
}

test "datetimeformat with no argument renders empty rather than the raw body" {
    const clock = Clock{ .now_ms = ref_ms };
    const got = (try resolve(t.allocator, "datetimeformat", clock)).?;
    defer t.allocator.free(got);
    try t.expectEqualStrings("", got);
}

test "timeDiff humanizes the gap between two stamps in both directions" {
    const clock = Clock{ .now_ms = ref_ms };
    const back = (try resolve(t.allocator, "timeDiff::2026-01-01 12:00:00::2026-01-01 15:00:00", clock)).?;
    defer t.allocator.free(back);
    try t.expectEqualStrings("3 hours ago", back);

    const forward = (try resolve(t.allocator, "timeDiff::2026-01-01 15:00:00::2026-01-01 12:00:00", clock)).?;
    defer t.allocator.free(forward);
    try t.expectEqualStrings("in 3 hours", forward);
}

test "timeDiff reads now against a date and declines an unparseable side" {
    const clock = Clock{ .now_ms = ref_ms };
    // moment's pastFuture uses diff > 0, so a zero difference reads as past, not future.
    const same = (try resolve(t.allocator, "timeDiff::now::now", clock)).?;
    defer t.allocator.free(same);
    try t.expectEqualStrings("a few seconds ago", same);

    const dated = (try resolve(t.allocator, "timeDiff::now::2026-07-13", clock)).?;
    defer t.allocator.free(dated);
    // 36.5 hours is past moment's 36h "a day" ceiling, so it rounds to whole days.
    try t.expectEqualStrings("in 2 days", dated);

    try t.expectEqual(@as(?[]u8, null), try resolve(t.allocator, "timeDiff::yesterday::now", clock));
    try t.expectEqual(@as(?[]u8, null), try resolve(t.allocator, "timeDiff::now", clock));
}

test "time macros release everything on any allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn run(a: Allocator) !void {
            const clock = Clock{ .now_ms = ref_ms, .idle_ms = std.time.ms_per_hour };
            for ([_][]const u8{ "time", "date", "weekday", "isotime", "isodate", "datetimeformat::LLLL", "idleDuration" }) |inner| {
                const got = (try resolve(a, inner, clock)) orelse return error.Unexpected;
                a.free(got);
            }
        }
    }.run, .{});
}
