//! The edge-tab reveal geometry: which side's flank a pointer is in.
//!
//! A side's tab reveals while the pointer is anywhere in that side's band of the window, bounded
//! above by the top bar and below by the composer, so the pointer never has to reach the tab itself.
//! Pure arithmetic, kept apart from pointer_track.zig (which owns the DOM measurement and the door
//! callback) so it can be proven in the native test suite.

const std = @import("std");

const ui_state = @import("./ui_state.zig");

pub const Side = ui_state.Side;

/// Band width as a share of the viewport. 0.28 puts the inner edge of a band at 403px on a 1440px
/// window, which reveals well before the pointer approaches the tab.
pub const flank_frac: f64 = 0.28;
/// Floor, so a narrow window keeps a usable band, and ceiling, so the two bands can never meet.
pub const flank_min_px: f64 = 200;
pub const flank_max_frac: f64 = 0.45;

/// Fallbacks for a viewport whose chrome cannot be measured: --topbar-h is 3rem, and the composer
/// row is about 76px tall at the default text size.
pub const fallback_top: f64 = 48;
pub const fallback_bottom_gap: f64 = 76;

pub const Zone = struct {
    w: f64,
    h: f64,
    top: f64,
    bottom: f64,
    flank: f64,

    /// True while the pointer is inside this side's band. A pointer reported outside the window
    /// (negative coordinates) is inside neither.
    pub fn contains(self: Zone, side: Side, x: f64, y: f64) bool {
        if (y < self.top or y > self.bottom) return false;
        return switch (side) {
            .left => x >= 0 and x <= self.flank,
            .right => x <= self.w and x >= self.w - self.flank,
        };
    }
};

/// The cap is applied last on purpose: below roughly 444px the floor is wider than the cap, and a
/// clamp with a lower bound above its upper bound asserts. The two bands must never meet, so the cap
/// wins and a very narrow window simply gets narrower bands.
pub fn flankWidth(viewport_w: f64) f64 {
    return @min(@max(viewport_w * flank_frac, flank_min_px), viewport_w * flank_max_frac);
}

/// The zone for a viewport. `topbar_bottom` and `composer_top` are the measured chrome edges; either
/// missing falls back to the CSS-derived constants above.
pub fn zoneFor(w: f64, h: f64, topbar_bottom: ?f64, composer_top: ?f64) Zone {
    return .{
        .w = w,
        .h = h,
        .top = topbar_bottom orelse fallback_top,
        .bottom = composer_top orelse (h - fallback_bottom_gap),
        .flank = flankWidth(w),
    };
}

const testing = std.testing;

test "the flank is a share of the viewport, floored on narrow windows and capped before mid-screen" {
    try testing.expectEqual(@as(f64, 403.20000000000005), flankWidth(1440));
    // 0.28 of 600 is 168, under the floor.
    try testing.expectEqual(flank_min_px, flankWidth(600));
    // The floor may never push a band past the cap, or the two sides would overlap.
    try testing.expectEqual(@as(f64, 180), flankWidth(400));
    try testing.expect(flankWidth(400) <= 400 * flank_max_frac);
}

test "a side reveals across its whole band and nowhere else" {
    const z = zoneFor(1440, 900, 48, 830);
    try testing.expectEqual(@as(f64, 403.20000000000005), z.flank);
    // Deep inside the band, far from the tab, both vertically and horizontally.
    try testing.expect(z.contains(.left, 380, 620));
    try testing.expect(z.contains(.left, 2, 400));
    try testing.expect(z.contains(.right, 1438, 700));
    try testing.expect(z.contains(.right, 1440 - 400, 60));
    // The centre column belongs to neither side.
    try testing.expect(!z.contains(.left, 720, 450));
    try testing.expect(!z.contains(.right, 720, 450));
    // One pixel past the inner edge is out.
    try testing.expect(!z.contains(.left, 404, 400));
    try testing.expect(!z.contains(.right, 1036, 400));
}

test "the top bar and the composer are excluded, as is a pointer that left the window" {
    const z = zoneFor(1440, 900, 48, 830);
    try testing.expect(!z.contains(.left, 200, 20));
    try testing.expect(!z.contains(.left, 200, 47));
    try testing.expect(z.contains(.left, 200, 48));
    try testing.expect(z.contains(.left, 200, 830));
    try testing.expect(!z.contains(.left, 200, 831));
    try testing.expect(!z.contains(.left, -1, -1));
    try testing.expect(!z.contains(.right, -1, -1));
}

test "unmeasurable chrome falls back to the CSS-derived bounds" {
    const z = zoneFor(1440, 900, null, null);
    try testing.expectEqual(fallback_top, z.top);
    try testing.expectEqual(@as(f64, 900 - fallback_bottom_gap), z.bottom);
    try testing.expect(z.contains(.left, 100, 500));
    try testing.expect(!z.contains(.left, 100, 40));
}
