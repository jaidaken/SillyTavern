//! The u64 door-packing convention for buffer handoffs to the JS pump: pointer in the high 32
//! bits, length in the low 32. The JS side unpacks with `Number(v >> 32n)` and
//! `Number(v & 0xffffffffn)`; `unpackPtr`/`unpackLen` are the Zig twins of those expressions so
//! the round-trip is provable natively. Any pointer above 2^21 packs to a value above 2^53, which
//! a JS Number cannot carry: this crossing is BigInt-only, and boundary_marshal.zig gates the
//! glue on that.

const std = @import("std");

pub fn pack(ptr: usize, len: usize) u64 {
    return (@as(u64, ptr) << 32) | @as(u64, @as(u32, @intCast(len)));
}

pub fn unpackPtr(v: u64) usize {
    return @intCast(v >> 32);
}

pub fn unpackLen(v: u64) usize {
    return @intCast(v & 0xffff_ffff);
}

const testing = std.testing;

test "pack round-trips pointers and lengths including values above 2^53" {
    const cases = [_]struct { ptr: usize, len: usize }{
        .{ .ptr = 0, .len = 0 },
        .{ .ptr = 0x1000, .len = 1 },
        // Above 2^21: the packed value exceeds 2^53 and dies in a JS Number.
        .{ .ptr = 0x0040_0001, .len = 77 },
        .{ .ptr = 0xffff_ffff, .len = 0xffff_ffff },
    };
    inline for (cases) |c| {
        const packed_v = pack(c.ptr, c.len);
        try testing.expectEqual(c.ptr, unpackPtr(packed_v));
        try testing.expectEqual(c.len, unpackLen(packed_v));
    }
    try testing.expectEqual(std.math.maxInt(u64), pack(0xffff_ffff, 0xffff_ffff));
}

test "pack round-trips under a seeded random sweep" {
    var prng = std.Random.DefaultPrng.init(0x48315f31);
    const random = prng.random();
    for (0..1000) |_| {
        const ptr = random.int(u32);
        const len = random.int(u32);
        const packed_v = pack(ptr, len);
        try testing.expectEqual(@as(usize, ptr), unpackPtr(packed_v));
        try testing.expectEqual(@as(usize, len), unpackLen(packed_v));
    }
}
