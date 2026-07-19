//! Byte-exact ports of the two deterministic primitives the `{{pick}}` macro needs from the old
//! frontend: cyrb53 string hashing (utils.js:525 getStringHash) and seedrandom's numeric-seed ARC4
//! generator (node_modules/seedrandom/seedrandom.js). `{{pick}}` reproduces the classic client's
//! index selection exactly, so a card that picked "red" there still picks "red" here.
//!
//! `{{roll}}` and `{{random}}` are genuinely random in stock (Math.random / entropy seedrandom), so
//! they take an injected `std.Random` instead and are proven by range/membership, not by value.
//!
//! zx-free, so `zig build test` proves it natively.

const std = @import("std");

fn imul(a: u32, b: u32) u32 {
    return a *% b;
}

/// Yields the UTF-16 code units of a UTF-8 slice, matching JS `String.prototype.charCodeAt`: a BMP
/// codepoint is one unit, an astral codepoint is a surrogate pair. Invalid UTF-8 falls back to one
/// unit per byte so a malformed input still hashes deterministically rather than trapping.
const Utf16Units = struct {
    bytes: []const u8,
    i: usize = 0,
    pending_low: ?u16 = null,

    fn next(self: *Utf16Units) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        if (self.i >= self.bytes.len) return null;

        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch return self.oneByte();
        if (self.i + len > self.bytes.len) return self.oneByte();
        const cp = std.unicode.utf8Decode(self.bytes[self.i .. self.i + len]) catch return self.oneByte();
        self.i += len;

        if (cp <= 0xFFFF) return @intCast(cp);
        const c = cp - 0x10000;
        self.pending_low = @intCast(0xDC00 + (c & 0x3FF));
        return @intCast(0xD800 + (c >> 10));
    }

    fn oneByte(self: *Utf16Units) u16 {
        const b = self.bytes[self.i];
        self.i += 1;
        return b;
    }
};

/// cyrb53 (utils.js:525): a 53-bit string hash over UTF-16 code units. Always non-negative and below
/// 2^53, so it round-trips through `i64` and formats to the same decimal JS `String(number)` gives.
pub fn getStringHash(str: []const u8, seed: u32) i64 {
    var h1: u32 = 0xdeadbeef ^ seed;
    var h2: u32 = 0x41c6ce57 ^ seed;

    var it = Utf16Units{ .bytes = str };
    while (it.next()) |unit| {
        const ch: u32 = unit;
        h1 = imul(h1 ^ ch, 2654435761);
        h2 = imul(h2 ^ ch, 1597334677);
    }

    h1 = imul(h1 ^ (h1 >> 16), 2246822507) ^ imul(h2 ^ (h2 >> 13), 3266489909);
    h2 = imul(h2 ^ (h2 >> 16), 2246822507) ^ imul(h1 ^ (h1 >> 13), 3266489909);

    const hi: i64 = @as(i64, 2097151 & h2) * 4294967296;
    return hi + @as(i64, h1);
}

/// seedrandom's default ARC4 generator, seeded as the deployed CST macro engine does it:
/// `seedrandom(String(finalSeed))`. A STRING seed's `flatten` is the digits with NO trailing NUL
/// (a number seed would append one); `mixkey` folds it into the ARC4 key, the key schedule runs, and
/// RC4-drop[256] discards the first 256 outputs.
pub const Seedrandom = struct {
    s: [256]u8,
    i: u32,
    j: u32,

    pub fn init(numeric_seed: i64) Seedrandom {
        var key: [256]u8 = undefined;
        var keylen: usize = 0;
        var smear: u32 = 0;

        var digits: [21]u8 = undefined;
        const decimal = decWrite(&digits, @intCast(numeric_seed));
        // Stock's pick uses seedrandom(String(finalSeed)); a STRING seed appends NO trailing NUL, unlike
        // a number seed. The deployed CST macro engine (core-macros.js:404) uses this string form.
        const total = decimal.len;

        var jj: usize = 0;
        while (jj < total) : (jj += 1) {
            const idx = jj & 255;
            const cur: u32 = if (idx < keylen) key[idx] else 0;
            smear = smear ^ (cur *% 19);
            const ch: u32 = decimal[jj];
            key[idx] = @intCast((smear +% ch) & 0xFF);
            if (idx + 1 > keylen) keylen = idx + 1;
        }

        var self = Seedrandom{ .s = undefined, .i = 0, .j = 0 };
        for (0..256) |i| self.s[i] = @intCast(i);
        var jk: u32 = 0;
        for (0..256) |i| {
            jk = (jk + self.s[i] + key[i % keylen]) & 255;
            const t = self.s[i];
            self.s[i] = self.s[jk];
            self.s[jk] = t;
        }
        _ = self.g(256);
        return self;
    }

    fn g(self: *Seedrandom, count: usize) u64 {
        var r: u64 = 0;
        var i = self.i;
        var j = self.j;
        var c = count;
        while (c > 0) : (c -= 1) {
            i = (i + 1) & 255;
            const t = self.s[i];
            j = (j + t) & 255;
            const si_new = self.s[j];
            self.s[i] = si_new;
            self.s[j] = t;
            const idx = (@as(u32, si_new) + @as(u32, t)) & 255;
            // count is 6 or 1 for observed draws (r < 2^48, exact); the discarded drop-256 call
            // overflows in JS floats too, so wrap it rather than trap.
            r = r *% 256 +% self.s[idx];
        }
        self.i = i;
        self.j = j;
        return r;
    }

    /// One random double in [0, 1) with randomness in every mantissa bit, formed exactly as
    /// seedrandom's default `prng()` (six ARC4 bytes, fill, then trim to avoid rounding up).
    pub fn next(self: *Seedrandom) f64 {
        const width: f64 = 256.0;
        const significance: f64 = 4503599627370496.0; // 2^52
        const overflow_v: f64 = 9007199254740992.0; // 2^53
        var n: f64 = @floatFromInt(self.g(6));
        var d: f64 = 281474976710656.0; // 2^48
        var x: f64 = 0;
        while (n < significance) {
            n = (n + x) * width;
            d = d * width;
            x = @floatFromInt(self.g(1));
        }
        while (n >= overflow_v) {
            n = n / 2.0;
            d = d / 2.0;
            const xu: u32 = @intFromFloat(x);
            x = @floatFromInt(xu >> 1);
        }
        return (n + x) / d;
    }
};

/// The `{{pick}}` index: seed off chat id, raw content, and the macro's byte offset (getPickReplaceMacro
/// macros.js:463), then `floor(rng() * len)`. Deterministic and byte-exact against the classic client.
pub fn pickIndex(chat_id: []const u8, raw_content: []const u8, offset: usize, list_len: usize) usize {
    if (list_len == 0) return 0;
    const chat_id_hash = getStringHash(chat_id, 0);
    const raw_content_hash = getStringHash(raw_content, 0);

    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    pos = decWriteAt(&buf, pos, @intCast(chat_id_hash));
    buf[pos] = '-';
    pos += 1;
    pos = decWriteAt(&buf, pos, @intCast(raw_content_hash));
    buf[pos] = '-';
    pos += 1;
    pos = decWriteAt(&buf, pos, offset);
    const combined = buf[0..pos];

    const final_seed = getStringHash(combined, 0);
    var sr = Seedrandom.init(final_seed);
    const v = sr.next() * @as(f64, @floatFromInt(list_len));
    return @intFromFloat(@floor(v));
}

fn decWrite(buf: []u8, val: u64) []u8 {
    return buf[0..decWriteAt(buf, 0, val)];
}

fn decWriteAt(buf: []u8, start: usize, val: u64) usize {
    if (val == 0) {
        buf[start] = '0';
        return start + 1;
    }
    var digits: [20]u8 = undefined;
    var n = val;
    var k: usize = 0;
    while (n > 0) : (n /= 10) {
        digits[k] = @intCast('0' + n % 10);
        k += 1;
    }
    var pos = start;
    while (k > 0) {
        k -= 1;
        buf[pos] = digits[k];
        pos += 1;
    }
    return pos;
}

const testing = std.testing;

test "getStringHash matches stock cyrb53 goldens over ascii and utf-16 code units" {
    try testing.expectEqual(@as(i64, 3338908027751811), getStringHash("", 0));
    try testing.expectEqual(@as(i64, 7929297801672961), getStringHash("a", 0));
    try testing.expectEqual(@as(i64, 4625896200565286), getStringHash("hello", 0));
    try testing.expectEqual(@as(i64, 5318283405637093), getStringHash("Chat_2024-01-15@10h30m", 0));
    try testing.expectEqual(@as(i64, 2323329309686887), getStringHash("café ☕ 🎲", 0));
    try testing.expectEqual(@as(i64, 8515397188529768), getStringHash("12345-67890-3", 0));
}

fn firstDouble(seed: i64) f64 {
    var sr = Seedrandom.init(seed);
    return sr.next();
}

// String-seed convention (no trailing NUL), matching the deployed CST engine's seedrandom(String(finalSeed)).
test "seedrandom string-seed first double matches the no-NUL arc4 draw" {
    try testing.expectEqual(@as(f64, 0.7803563384230067), firstDouble(0));
    try testing.expectEqual(@as(f64, 0.2694488477791326), firstDouble(1));
    try testing.expectEqual(@as(f64, 0.00701751618236155), firstDouble(42));
    try testing.expectEqual(@as(f64, 0.28299807513202446), firstDouble(123456789));
    try testing.expectEqual(@as(f64, 0.3669125993459986), firstDouble(9007199254740991));
}

test "pickIndex reproduces stock getPickReplaceMacro indices byte-exact" {
    try testing.expectEqual(@as(usize, 2), pickIndex("Chat_2024-01-15@10h30m", "You see {{pick::red::green::blue}} ahead.", 8, 3));
    try testing.expectEqual(@as(usize, 3), pickIndex("default", "{{pick: sword, shield, bow, staff}}", 0, 4));
    try testing.expectEqual(@as(usize, 1), pickIndex("branch-2", "a {{pick::x::y}} b {{pick::x::y}} c", 19, 2));
    try testing.expectEqual(@as(usize, 3), pickIndex("café ☕", "The 🎲 rolls {{pick::north,south,east,west}}", 12, 4));
    try testing.expectEqual(@as(usize, 0), pickIndex("Chat_2024-01-15@10h30m", "single {{pick::only}}", 7, 1));
}

// Anchored to STOCK's MEASURED output (browser --measurepick, seed 6000002 desc + 6000007 greeting):
// the exact field + chat id + offset the real frontend fed the pick, and the word it chose.
test "pickIndex matches the browser-measured stock pick word" {
    const chat = "Seraphina - 2023-5-12 @21h 32m 29s 224ms";
    const desc = "ZCARDDESCRIPTION_6000002Z a warded glade of beasts and old magic. {{pick::one,two,three}} {{user}}/{{char}} [[roll:{{roll:d20}}]] [[rnd:{{random::alpha,beta,gamma}}]] {{//c}}";
    try testing.expectEqual(@as(usize, 2), pickIndex(chat, desc, 66, 3)); // stock chose "three"
    const greeting = "ZCARDGREETING_6000007Z Hello {{user}}, I am {{char}}. {{pick::one,two,three}} {{user}}/{{char}} [[roll:{{roll:d20}}]] [[rnd:{{random::alpha,beta,gamma}}]] {{//c}}";
    try testing.expectEqual(@as(usize, 0), pickIndex(chat, greeting, 54, 3)); // stock chose "one"
}

test "seedrandom draws stay in the unit interval over many seeds" {
    for (0..2000) |seed| {
        var sr = Seedrandom.init(@intCast(seed));
        const v = sr.next();
        try testing.expect(v >= 0.0 and v < 1.0);
    }
}
