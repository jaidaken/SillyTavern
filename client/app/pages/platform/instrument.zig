//! Render-count instrumentation for the memoization + region-scoping measurement, comptime-gated by
//! `-Dinstrument`.
//!
//! `MessageView` bumps `message_view_renders` once per resolution; each sibling region (Shell,
//! MessageLog, Composer) bumps its own counter once per render. The door exposes the counters so the
//! headless harness can read per-token and per-toggle deltas: a token must re-render only MessageLog
//! (and resolve exactly one MessageView), a panel toggle only Shell. Production builds leave
//! `-Dinstrument` off (build.sh), so `enabled` is comptime false, every `bump` folds to nothing, and
//! the counters, their door exports, and the harness path all vanish. The wasm stays ReleaseSmall in
//! both builds.

const build_options = @import("build_options");

pub const enabled: bool = build_options.instrument;

// wasm is single-threaded and these are only ever touched on the render path, like store.global.
var message_view_renders: usize = 0;
var shell_renders: usize = 0;
var message_log_renders: usize = 0;
var composer_renders: usize = 0;

/// Counts one `MessageView` resolution. A no-op when instrumentation is compiled out.
pub inline fn bump() void {
    if (enabled) message_view_renders += 1;
}

/// Counts one Shell region render. A no-op when instrumentation is compiled out.
pub inline fn bumpShell() void {
    if (enabled) shell_renders += 1;
}

/// Counts one MessageLog region render. A no-op when instrumentation is compiled out.
pub inline fn bumpMessageLog() void {
    if (enabled) message_log_renders += 1;
}

/// Counts one Composer region render. A no-op when instrumentation is compiled out.
pub inline fn bumpComposer() void {
    if (enabled) composer_renders += 1;
}

/// Total `MessageView` resolutions since process start. The harness reads deltas across tokens.
pub fn messageViewRenders() usize {
    return message_view_renders;
}

/// Total Shell region renders since process start.
pub fn shellRenders() usize {
    return shell_renders;
}

/// Total MessageLog region renders since process start.
pub fn messageLogRenders() usize {
    return message_log_renders;
}

/// Total Composer region renders since process start.
pub fn composerRenders() usize {
    return composer_renders;
}
