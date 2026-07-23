//! The open chat's timed-effect state (stock chat_metadata.timedWorldInfo): the sticky + cooldown
//! windows that must persist across sends. world_info_engine owns the machine and the JSON codec
//! (both natively tested); this module only HOLDS the per-chat state between a chat open and each
//! send. char_api reads current() into the send Shape, and after a send calls advance() with the
//! JSON the builder produced so the next send sees this send's outcome. Server durability rides a
//! separate /api/chats/metadata write in char_api; this in-memory copy is what the next send reads.

const std = @import("std");
const engine = @import("./world_info_engine.zig");
const char_store = @import("../cast/character_store.zig");

const alloc = char_store.page_gpa;

/// The held slices live in `arena`; every reseat frees the whole arena and starts a fresh one, so a
/// chat switch or a send advance can never leave the state pointing at freed bytes.
var arena: ?std.heap.ArenaAllocator = null;
var state: engine.TimedState = .{};

fn reseat() std.mem.Allocator {
    if (arena) |*a| a.deinit();
    arena = std.heap.ArenaAllocator.init(alloc);
    state = .{};
    return arena.?.allocator();
}

/// The state to feed the send Shape's wi_timed_in. Borrowed; valid until the next setFromMetadata /
/// advance / clear.
pub fn current() engine.TimedState {
    return state;
}

/// Whether any window is live. Gates the server persist: a chat that never touches a sticky/cooldown
/// entry stays off the /metadata write path entirely.
pub fn hasState() bool {
    return state.sticky.len > 0 or state.cooldown.len > 0;
}

/// The held state as the stock timedWorldInfo JSON value, for the /metadata write body. Built in `a`;
/// the keys still reference this module's arena, so stringify before the next reseat.
pub fn toValue(a: std.mem.Allocator) std.mem.Allocator.Error!std.json.Value {
    return engine.writeTimedState(a, state);
}

/// Chat open: seat the state from the chat header's metadata JSON (its timedWorldInfo field).
pub fn setFromMetadata(chat_metadata: []const u8) void {
    const a = reseat();
    state = engine.readTimedFromMetadata(a, chat_metadata);
}

/// After a send: reseat from the bare timed-state JSON the builder produced (and char_api persisted),
/// so the next send's wi_timed_in is this send's outcome.
pub fn advance(timed_json: []const u8) void {
    const a = reseat();
    state = engine.readTimedFromJson(a, timed_json);
}

/// No chat open: drop the held state so a stale window can never bleed into an unrelated chat.
pub fn clear() void {
    _ = reseat();
}
