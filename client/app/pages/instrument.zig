//! Render-count instrumentation for the memoization measurement, comptime-gated by `-Dinstrument`.
//!
//! `MessageView` bumps `message_view_renders` once per resolution; the door exposes the counter so
//! the headless harness can read the per-token render count. Production builds leave `-Dinstrument`
//! off (build.sh), so `enabled` is comptime false, `bump` folds to nothing, and the counter, its
//! door export, and the harness path all vanish. The wasm stays ReleaseSmall in both builds.

const build_options = @import("build_options");

pub const enabled: bool = build_options.instrument;

// wasm is single-threaded and this is only ever touched on the render path, like store.global.
var message_view_renders: usize = 0;

/// Counts one `MessageView` resolution. A no-op when instrumentation is compiled out.
pub inline fn bump() void {
    if (enabled) message_view_renders += 1;
}

/// Total `MessageView` resolutions since process start. The harness reads deltas across tokens.
pub fn messageViewRenders() usize {
    return message_view_renders;
}
