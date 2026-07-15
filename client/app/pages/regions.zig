//! Region render handles for the sibling client components (Shell, MessageLog).
//!
//! Each region publishes its `ctx.state` handle here on first render; the door (`bridge.zig`) and
//! the ui glue (`ui.zig`) call the bump helpers to re-render ONLY the owning region instead of the
//! whole page. A neutral plain-Zig module so both the `.zx` regions and the plain-Zig door/ui can
//! reach the handles without a `.zig` importing a `.zx` (or a `bridge <-> region` import cycle).
//!
//! The handle's value is a dummy version counter: a region render reads its data from `store`/`ui`,
//! not from the handle, so `set` serves only to schedule the scoped re-render. `set` calls
//! `scheduleRender(component_id)` unconditionally, so bumping always re-renders. On SSR the handles
//! are still assigned but `scheduleRender` is a no-op (not wasm), so bumping is harmless there.

const zx = @import("zx");

pub var shell: ?*zx.State(u32) = null;
pub var message_log: ?*zx.State(u32) = null;
pub var character_list: ?*zx.State(u32) = null;
pub var home: ?*zx.State(u32) = null;

/// Re-render the Shell region (topbar + docks) after a ui mutation. No-op before its first render.
/// Also bumps Home: a character-store load (recomputeView) and a chat open both fire this, and Home's
/// visibility + row names track those, so it re-renders in lockstep with the shell.
pub fn bumpShell() void {
    if (shell) |h| h.set(h.get() +% 1);
    bumpHome();
}

/// Re-render the MessageLog region (the chat log) after a store/stream mutation. No-op before its
/// first render. Does NOT bump Home: this fires per stream flush, and Home's visibility only flips on
/// a chat OPEN (which also fires bumpShell) or a demo seed (which bumps Home explicitly), so bumping
/// here would re-render the hidden Home once per streamed token for no visible change.
pub fn bumpMessageLog() void {
    if (message_log) |h| h.set(h.get() +% 1);
}

/// Re-render only the Home region (the recent-chats landing) after a recent-list load or a
/// visibility change. No-op before its first render.
pub fn bumpHome() void {
    if (home) |h| h.set(h.get() +% 1);
}

/// Re-render only the character list subtree (not its toolbar) after a filter/search change, so the
/// search input keeps focus. No-op before its first render.
pub fn bumpCharacterList() void {
    if (character_list) |h| h.set(h.get() +% 1);
}
