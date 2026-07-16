//! Local re-masking of a secret before it can reach the DOM.
//!
//! `/api/secrets/read` returns the value in the CLEAR when the server runs with
//! allowKeysExposure=true (src/endpoints/secrets.js getMaskedValue), so this is the only guard
//! standing between a live API key and the rendered page. It is pure and zx-free so it joins the
//! native `zig build test` aggregator (ZX5): the guard is proven here without a browser, as well as
//! end-to-end by the C-CONN-10 gate row against a server armed to serve raw keys.

const std = @import("std");

/// The masked form's fixed width. Chosen to be too narrow to carry a key, so a caller that hands
/// over a raw value cannot widen the output into a leak.
pub const width = 10;

/// How many trailing characters survive, matching what the server's own mask exposes.
pub const exposed = 3;

/// The masked form of `value`: an asterisk run ending in at most its last `exposed` characters.
/// Always exactly `width` bytes, whatever the input length.
///
/// ```
/// var buf: [secret_mask.width]u8 = undefined;
/// try std.testing.expectEqualStrings("*******xyz", secret_mask.mask("a-very-long-secret-xyz", &buf));
/// ```
pub fn mask(value: []const u8, out: *[width]u8) []const u8 {
    out.* = @splat('*');
    if (value.len > exposed) {
        @memcpy(out[width - exposed ..], value[value.len - exposed ..]);
    }
    return out[0..width];
}

test "a masked key is always the fixed width whatever the input length" {
    var buf: [width]u8 = undefined;
    const inputs = [_][]const u8{ "", "a", "abc", "abcd", "0123456789", "a-very-long-secret-key-0001" };
    for (inputs) |in| {
        try std.testing.expectEqual(width, mask(in, &buf).len);
    }
}

test "a long value keeps only its last three characters behind an asterisk run" {
    var buf: [width]u8 = undefined;
    try std.testing.expectEqualStrings("*******xyz", mask("a-very-long-secret-xyz", &buf));
    try std.testing.expectEqualStrings("*******001", mask("dummy-tabby-key-for-the-gate-0001", &buf));
    try std.testing.expectEqualStrings("*******7xy", mask("dummy-exposed-key-7xy", &buf));
}

test "a value at or under the exposed length reveals nothing at all" {
    var buf: [width]u8 = undefined;
    try std.testing.expectEqualStrings("**********", mask("", &buf));
    try std.testing.expectEqualStrings("**********", mask("a", &buf));
    try std.testing.expectEqualStrings("**********", mask("abc", &buf));
}

test "the mask never reproduces a raw key that the server returned in the clear" {
    // The dangerous property: whatever the server hands over, the output cannot carry it. Mirrors
    // the C-CONN-10 gate row at the unit level, where no dist build or browser can race it.
    var buf: [width]u8 = undefined;
    const raw_keys = [_][]const u8{
        "sk-live-0123456789abcdefghijklmnop",
        "dummy-exposed-key-7xy",
        "0123456789ab",
        "abcdefghijk",
    };
    for (raw_keys) |raw| {
        const masked = mask(raw, &buf);
        try std.testing.expect(std.mem.indexOf(u8, masked, raw) == null);
        try std.testing.expect(masked.len < raw.len);
        // Only the tail survives: everything before it is masked, so no interior run leaks either.
        try std.testing.expectEqualStrings("*" ** (width - exposed), masked[0 .. width - exposed]);
    }
}

test "masking is deterministic and reuses the caller buffer without carrying prior state" {
    var buf: [width]u8 = undefined;
    const first = try std.testing.allocator.dupe(u8, mask("first-secret-aaa", &buf));
    defer std.testing.allocator.free(first);
    _ = mask("second-secret-bbb", &buf);
    const again = mask("first-secret-aaa", &buf);
    try std.testing.expectEqualStrings(first, again);
    try std.testing.expectEqualStrings("*******aaa", again);
}
