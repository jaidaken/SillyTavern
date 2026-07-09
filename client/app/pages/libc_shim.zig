//! md4c is C and expects a libc. On wasm32-freestanding there is none: compiler_rt supplies
//! mem{cpy,move,set,cmp}, but the allocator and string helpers must be provided here.
//! Every block carries an 8-byte size header because Zig's free() needs the original length.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// Allocator bootstrap: these ARE malloc/free. On wasm the exports are the only heap; natively
/// the tests exercise the same code over libc's heap.
const backing = if (is_wasm) std.heap.wasm_allocator else std.heap.c_allocator;
const header = @sizeOf(usize);
const testing = std.testing;

fn alloc(size: usize) callconv(.c) ?*anyopaque {
    const block = backing.alignedAlloc(u8, .of(usize), header + size) catch return null;
    @as(*usize, @ptrCast(@alignCast(block.ptr))).* = size;
    return @ptrCast(block.ptr + header);
}

fn blockOf(ptr: *anyopaque) []align(@alignOf(usize)) u8 {
    const base: [*]u8 = @as([*]u8, @ptrCast(ptr)) - header;
    const size = @as(*const usize, @ptrCast(@alignCast(base))).*;
    return @alignCast(base[0 .. header + size]);
}

fn release(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    backing.free(blockOf(p));
}

fn resize(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const p = ptr orelse return alloc(size);
    const old = blockOf(p);
    const old_size = old.len - header;
    const fresh = alloc(size) orelse return null;
    const copy = @min(old_size, size);
    @memcpy(@as([*]u8, @ptrCast(fresh))[0..copy], @as([*]const u8, @ptrCast(p))[0..copy]);
    backing.free(old);
    return fresh;
}

fn length(s: [*:0]const u8) callconv(.c) usize {
    return std.mem.len(s);
}

fn compareN(a: [*c]const u8, b: [*c]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return @as(c_int, a[i]) - @as(c_int, b[i]);
        if (a[i] == 0) return 0;
    }
    return 0;
}

fn findChar(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]const u8 {
    const needle: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == needle) return s + i;
        if (s[i] == 0) return null;
    }
}

/// md4c only ever formats `%u`. `%s` and `%%` are handled so a future call site cannot corrupt.
fn formatInto(buf: [*c]u8, size: usize, fmt: [*c]const u8, ap: *std.builtin.VaList) callconv(.c) c_int {
    var written: usize = 0;
    var i: usize = 0;

    const put = struct {
        fn one(b: [*c]u8, cap: usize, n: *usize, ch: u8) void {
            if (n.* + 1 < cap) b[n.*] = ch;
            n.* += 1;
        }
    };

    while (fmt[i] != 0) : (i += 1) {
        if (fmt[i] != '%') {
            put.one(buf, size, &written, fmt[i]);
            continue;
        }
        i += 1;
        switch (fmt[i]) {
            'u' => {
                var digits: [10]u8 = undefined;
                var v: c_uint = @cVaArg(ap, c_uint);
                var n: usize = 0;
                if (v == 0) {
                    digits[0] = '0';
                    n = 1;
                } else while (v != 0) : (v /= 10) {
                    digits[n] = '0' + @as(u8, @intCast(v % 10));
                    n += 1;
                }
                while (n > 0) {
                    n -= 1;
                    put.one(buf, size, &written, digits[n]);
                }
            },
            's' => {
                const s: [*:0]const u8 = @cVaArg(ap, [*:0]const u8);
                var j: usize = 0;
                while (s[j] != 0) : (j += 1) put.one(buf, size, &written, s[j]);
            },
            '%' => put.one(buf, size, &written, '%'),
            // C says a negative return is an encoding error. md4c only ever formats %u, so an
            // unknown conversion means a new call site, not a runtime condition. Fail loudly.
            else => {
                if (size > 0) buf[0] = 0;
                return -1;
            },
        }
    }

    if (size > 0) buf[@min(written, size - 1)] = 0;
    return @intCast(written);
}

fn snprintf(buf: [*c]u8, size: usize, fmt: [*c]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return formatInto(buf, size, fmt, &ap);
}

const Cmp = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;

fn elem(base: [*]u8, width: usize, i: usize) [*]u8 {
    return base + i * width;
}

/// Shell sort with Ciura gaps: no recursion, no scratch allocation beyond one element.
fn qsort(base: ?*anyopaque, n: usize, width: usize, cmp: Cmp) callconv(.c) void {
    const b: [*]u8 = @ptrCast(base orelse return);
    if (n < 2 or width == 0) return;

    const tmp = alloc(width) orelse return;
    defer release(tmp);
    const t: [*]u8 = @ptrCast(tmp);

    const gaps = [_]usize{ 701, 301, 132, 57, 23, 10, 4, 1 };
    for (gaps) |gap| {
        if (gap >= n) continue;
        var i: usize = gap;
        while (i < n) : (i += 1) {
            @memcpy(t[0..width], elem(b, width, i)[0..width]);
            var j: usize = i;
            while (j >= gap and cmp(elem(b, width, j - gap), t) > 0) : (j -= gap) {
                @memcpy(elem(b, width, j)[0..width], elem(b, width, j - gap)[0..width]);
            }
            @memcpy(elem(b, width, j)[0..width], t[0..width]);
        }
    }
}

fn bsearch(key: ?*const anyopaque, base: ?*const anyopaque, n: usize, width: usize, cmp: Cmp) callconv(.c) ?*anyopaque {
    const b: [*]u8 = @ptrCast(@constCast(base orelse return null));
    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = elem(b, width, mid);
        const order = cmp(key, at);
        if (order == 0) return @ptrCast(at);
        if (order < 0) hi = mid else lo = mid + 1;
    }
    return null;
}

fn cmpU32(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const x: *const u32 = @ptrCast(@alignCast(a.?));
    const y: *const u32 = @ptrCast(@alignCast(b.?));
    if (x.* < y.*) return -1;
    if (x.* > y.*) return 1;
    return 0;
}

test "snprintf_formats_unsigned_and_truncates_without_overflow" {
    var buf: [32]u8 = undefined;
    var n = snprintf(&buf, buf.len, "<ol start=\"%u\">", @as(c_uint, 7));
    try testing.expectEqualStrings("<ol start=\"7\">", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%u", @as(c_uint, 0));
    try testing.expectEqualStrings("0", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%u", @as(c_uint, 4294967295));
    try testing.expectEqualStrings("4294967295", buf[0..@intCast(n)]);

    var small: [4]u8 = undefined;
    n = snprintf(&small, small.len, "%u", @as(c_uint, 123456));
    try testing.expectEqual(@as(c_int, 6), n);
    try testing.expectEqualStrings("123", small[0..3]);
    try testing.expectEqual(@as(u8, 0), small[3]);
}

test "snprintf_handles_string_and_literal_percent" {
    var buf: [32]u8 = undefined;
    const n = snprintf(&buf, buf.len, "%s%%%s", "ab", "cd");
    try testing.expectEqualStrings("ab%cd", buf[0..@intCast(n)]);
}

test "snprintf_returns_negative_on_an_unsupported_conversion" {
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(c_int, -1), snprintf(&buf, buf.len, "%d", @as(c_int, 5)));
    try testing.expectEqual(@as(u8, 0), buf[0]);

    try testing.expectEqual(@as(c_int, -1), snprintf(&buf, buf.len, "trailing %"));
}

test "qsort_orders_ascending_and_bsearch_locates_or_returns_null" {
    var data = [_]u32{ 9, 1, 8, 2, 7, 3, 6, 4, 5, 0 };
    qsort(&data, data.len, @sizeOf(u32), cmpU32);
    for (data, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);

    var key: u32 = 7;
    const hit = bsearch(&key, &data, data.len, @sizeOf(u32), cmpU32);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(u32, 7), @as(*const u32, @ptrCast(@alignCast(hit.?))).*);

    key = 42;
    try testing.expect(bsearch(&key, &data, data.len, @sizeOf(u32), cmpU32) == null);
}

test "qsort_sorts_a_sequence_longer_than_the_largest_ciura_gap" {
    var data: [800]u32 = undefined;
    for (&data, 0..) |*v, i| v.* = @intCast(800 - i);
    qsort(&data, data.len, @sizeOf(u32), cmpU32);
    for (data, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i + 1)), v);
}

test "strncmp_and_strchr_match_c_semantics" {
    try testing.expectEqual(@as(c_int, 0), compareN("language-zig", "language-abc", 9));
    try testing.expect(compareN("abc", "abd", 3) < 0);
    try testing.expect(findChar("a-b", '-') != null);
    try testing.expect(findChar("abc", 'z') == null);
}

comptime {
    if (is_wasm) {
        @export(&alloc, .{ .name = "malloc" });
        @export(&release, .{ .name = "free" });
        @export(&resize, .{ .name = "realloc" });
        @export(&length, .{ .name = "strlen" });
        @export(&findChar, .{ .name = "strchr" });
        @export(&compareN, .{ .name = "strncmp" });
        @export(&snprintf, .{ .name = "snprintf" });
        @export(&qsort, .{ .name = "qsort" });
        @export(&bsearch, .{ .name = "bsearch" });
    }
}
