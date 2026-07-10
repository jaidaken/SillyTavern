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

/// Re-render the Shell region (topbar + docks) after a ui mutation. No-op before its first render.
pub fn bumpShell() void {
    if (shell) |h| h.set(h.get() +% 1);
}

/// Re-render the MessageLog region (the chat log) after a store/stream mutation. No-op before its
/// first render.
pub fn bumpMessageLog() void {
    if (message_log) |h| h.set(h.get() +% 1);
}
