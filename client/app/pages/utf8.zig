//! Incremental UTF-8 decoding for the SSE byte stream.
//!
//! A network chunk boundary falls wherever TCP puts it, so a multibyte codepoint routinely arrives
//! split across two chunks. The decoder holds the trailing bytes of a truncated sequence and
//! completes them from the next chunk, so no codepoint is ever corrupted by the split.
//!
//! Malformed input yields U+FFFD and resynchronises on the offending byte, matching the WHATWG
//! encoding standard that the browser's own `TextDecoder` implements. Output is always valid UTF-8.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const replacement = "\u{FFFD}";

/// Unicode 15 table 3-7. The second byte's legal range narrows for E0, ED, F0 and F4, which is what
/// rejects overlong forms, surrogate halves and codepoints above U+10FFFF without a decode step.
const Lead = struct { need: usize, lo2: u8, hi2: u8 };

fn leadInfo(b: u8) ?Lead {
    return switch (b) {
        0x00...0x7f => .{ .need = 1, .lo2 = 0, .hi2 = 0 },
        0xc2...0xdf => .{ .need = 2, .lo2 = 0x80, .hi2 = 0xbf },
        0xe0 => .{ .need = 3, .lo2 = 0xa0, .hi2 = 0xbf },
        0xe1...0xec => .{ .need = 3, .lo2 = 0x80, .hi2 = 0xbf },
        0xed => .{ .need = 3, .lo2 = 0x80, .hi2 = 0x9f },
        0xee...0xef => .{ .need = 3, .lo2 = 0x80, .hi2 = 0xbf },
        0xf0 => .{ .need = 4, .lo2 = 0x90, .hi2 = 0xbf },
        0xf1...0xf3 => .{ .need = 4, .lo2 = 0x80, .hi2 = 0xbf },
        0xf4 => .{ .need = 4, .lo2 = 0x80, .hi2 = 0x8f },
        else => null,
    };
}

pub const Decoder = struct {
    partial: [4]u8 = undefined,
    partial_len: usize = 0,
    lead: Lead = .{ .need = 0, .lo2 = 0, .hi2 = 0 },

    /// Legal range for the byte at `pos` of a sequence opened by `lead`.
    fn accepts(lead: Lead, pos: usize, b: u8) bool {
        const lo: u8 = if (pos == 1) lead.lo2 else 0x80;
        const hi: u8 = if (pos == 1) lead.hi2 else 0xbf;
        return b >= lo and b <= hi;
    }

    /// Returns the validated UTF-8 decoded from `chunk`, minus any trailing truncated sequence,
    /// which is held for the next call. Caller owns the result.
    pub fn feed(self: *Decoder, allocator: Allocator, chunk: []const u8) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        if (self.partial_len > 0) i = try self.completeHeld(allocator, &out, chunk);

        outer: while (i < chunk.len) {
            const lead = leadInfo(chunk[i]) orelse {
                try out.appendSlice(allocator, replacement);
                i += 1;
                continue;
            };

            var n: usize = 1;
            while (n < lead.need) : (n += 1) {
                if (i + n == chunk.len) {
                    @memcpy(self.partial[0..n], chunk[i..]);
                    self.partial_len = n;
                    self.lead = lead;
                    break :outer;
                }
                if (!accepts(lead, n, chunk[i + n])) {
                    // One replacement per maximal subpart, then resynchronise on the offending byte.
                    try out.appendSlice(allocator, replacement);
                    i += n;
                    continue :outer;
                }
            }

            try out.appendSlice(allocator, chunk[i..][0..lead.need]);
            i += lead.need;
        }

        return out.toOwnedSlice(allocator);
    }

    /// Ends the stream. A held sequence at its full length was completed but not emitted because an
    /// allocation failure interrupted completeHeld's append, so emit the real codepoint; a shorter
    /// held sequence was truncated by the peer, so replace it with U+FFFD.
    pub fn flush(self: *Decoder, allocator: Allocator) Allocator.Error![]u8 {
        if (self.partial_len == 0) return allocator.alloc(u8, 0);
        const bytes = if (self.partial_len == self.lead.need) self.partial[0..self.partial_len] else replacement;
        self.partial_len = 0;
        return allocator.dupe(u8, bytes);
    }

    /// Extends the held sequence from `chunk`. Returns the index where ordinary scanning resumes.
    fn completeHeld(
        self: *Decoder,
        allocator: Allocator,
        out: *std.ArrayList(u8),
        chunk: []const u8,
    ) Allocator.Error!usize {
        var i: usize = 0;
        while (self.partial_len < self.lead.need) {
            if (i == chunk.len) return i;
            if (!accepts(self.lead, self.partial_len, chunk[i])) {
                try out.appendSlice(allocator, replacement);
                self.partial_len = 0;
                return i;
            }
            self.partial[self.partial_len] = chunk[i];
            self.partial_len += 1;
            i += 1;
        }

        try out.appendSlice(allocator, self.partial[0..self.lead.need]);
        self.partial_len = 0;
        return i;
    }
};

const testing = std.testing;

fn feedAll(allocator: Allocator, chunks: []const []const u8) Allocator.Error![]u8 {
    var d = Decoder{};
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (chunks) |c| {
        const text = try d.feed(allocator, c);
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
    }
    const tail = try d.flush(allocator);
    defer allocator.free(tail);
    try out.appendSlice(allocator, tail);

    return out.toOwnedSlice(allocator);
}

test "decoder_reassembles_a_codepoint_split_across_two_chunks" {
    const emoji = "\u{1F600}";
    const got = try feedAll(testing.allocator, &.{ emoji[0..2], emoji[2..4] });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(emoji, got);
}

test "decoder_reassembles_a_codepoint_split_one_byte_at_a_time" {
    const cjk = "\u{4E16}\u{754C}";
    const got = try feedAll(testing.allocator, &.{
        cjk[0..1], cjk[1..2], cjk[2..3], cjk[3..4], cjk[4..5], cjk[5..6],
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(cjk, got);
}

test "decoder_holds_a_truncated_sequence_and_emits_nothing_for_it_yet" {
    var d = Decoder{};
    const emoji = "\u{1F600}";

    const first = try d.feed(testing.allocator, emoji[0..3]);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("", first);
    try testing.expectEqual(@as(usize, 3), d.partial_len);

    const second = try d.feed(testing.allocator, emoji[3..4]);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(emoji, second);
    try testing.expectEqual(@as(usize, 0), d.partial_len);
}

test "decoder_splits_a_codepoint_without_disturbing_surrounding_ascii" {
    const src = "ab\u{4E16}cd";
    const got = try feedAll(testing.allocator, &.{ src[0..3], src[3..] });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(src, got);
}

test "decoder_replaces_an_invalid_start_byte" {
    const got = try feedAll(testing.allocator, &.{"a\xffb"});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a" ++ replacement ++ "b", got);
}

test "decoder_replaces_an_overlong_encoding" {
    // C0 is never a legal lead byte, so C0 and AF are each their own maximal subpart.
    const got = try feedAll(testing.allocator, &.{"\xc0\xaf"});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(replacement ++ replacement, got);
}

test "decoder_replaces_a_surrogate_half" {
    // ED admits only 80..9F as its second byte, so A0 truncates the subpart to ED alone.
    const got = try feedAll(testing.allocator, &.{"\xed\xa0\x80"});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(replacement ++ replacement ++ replacement, got);
}

test "decoder_replaces_a_codepoint_above_the_unicode_maximum" {
    const got = try feedAll(testing.allocator, &.{"\xf4\x90\x80\x80"});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(replacement ** 4, got);
}

test "decoder_accepts_the_highest_legal_codepoint" {
    const got = try feedAll(testing.allocator, &.{"\u{10FFFF}"});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\u{10FFFF}", got);
}

test "decoder_resynchronises_when_a_continuation_byte_is_missing" {
    const got = try feedAll(testing.allocator, &.{"\xe4\xb8a"});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(replacement ++ "a", got);
}

test "decoder_resynchronises_when_a_held_sequence_is_cut_short_by_the_next_chunk" {
    const got = try feedAll(testing.allocator, &.{ "\xe4\xb8", "a" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(replacement ++ "a", got);
}

test "decoder_flushes_a_dangling_partial_as_a_replacement" {
    const got = try feedAll(testing.allocator, &.{"\xf0\x9f"});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(replacement, got);
}

test "decoder_flushes_a_completed_codepoint_that_an_allocation_failure_left_unemitted" {
    const euro = "\u{20AC}";
    var d = Decoder{};

    const held = try d.feed(testing.allocator, euro[0..2]);
    testing.allocator.free(held);

    // The final byte completes the codepoint, but its append fails, so it stays held unemitted.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, d.feed(failing.allocator(), euro[2..3]));

    // Ending the stream must recover the real character, not replace a fully-received one with U+FFFD.
    const tail = try d.flush(testing.allocator);
    defer testing.allocator.free(tail);
    try testing.expectEqualStrings(euro, tail);
}

test "decoder_output_never_depends_on_where_the_chunks_are_cut" {
    const src = "hi \u{4E16}\u{754C} ok \u{1F600}\u{1F601} tail \u{00E9}\u{20AC}";
    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const rand = prng.random();

    for (0..2000) |_| {
        var d = Decoder{};
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);

        var at: usize = 0;
        while (at < src.len) {
            const take = @min(src.len - at, rand.uintLessThan(usize, 5) + 1);
            const text = try d.feed(testing.allocator, src[at..][0..take]);
            defer testing.allocator.free(text);
            try out.appendSlice(testing.allocator, text);
            at += take;
        }
        const tail = try d.flush(testing.allocator);
        defer testing.allocator.free(tail);
        try out.appendSlice(testing.allocator, tail);

        try testing.expectEqualStrings(src, out.items);
    }
}

test "decoder_never_panics_and_always_emits_valid_utf8_for_random_bytes" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    var bytes: [64]u8 = undefined;

    for (0..2000) |_| {
        rand.bytes(&bytes);
        var d = Decoder{};
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);

        var at: usize = 0;
        while (at < bytes.len) {
            const take = @min(bytes.len - at, rand.uintLessThan(usize, 8) + 1);
            const text = try d.feed(testing.allocator, bytes[at..][0..take]);
            defer testing.allocator.free(text);
            try out.appendSlice(testing.allocator, text);
            at += take;
        }
        const tail = try d.flush(testing.allocator);
        defer testing.allocator.free(tail);
        try out.appendSlice(testing.allocator, tail);

        try testing.expect(std.unicode.utf8ValidateSlice(out.items));
    }
}

fn decodeScenario(allocator: Allocator, chunks: usize) !void {
    const src = "a\u{4E16}b\u{1F600}c";
    var d = Decoder{};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var at: usize = 0;
    const step = @max(1, src.len / chunks);
    while (at < src.len) {
        const take = @min(src.len - at, step);
        const text = try d.feed(allocator, src[at..][0..take]);
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
        at += take;
    }
    const tail = try d.flush(allocator);
    defer allocator.free(tail);
    try out.appendSlice(allocator, tail);

    try testing.expectEqualStrings(src, out.items);
}

test "decoder_releases_everything_on_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeScenario, .{@as(usize, 5)});
}
