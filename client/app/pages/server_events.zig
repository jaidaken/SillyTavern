//! The server-event hub: where a live event crosses from the browser's EventSource into Zig.
//!
//! TRANSPORT ONLY. This records what arrived and hands it on; deciding what an event MEANS (which
//! reload to fire, which store to append to) is the router's job and lands separately. The split
//! matters because the reconnect belongs to the BROWSER: after a resume the server legitimately
//! replays events the client has already seen, so the id has to survive the crossing intact for a
//! router to dedupe on. A transport that dropped the id would make idempotency unbuildable.
//!
//! The last id seen is what the browser sends back as Last-Event-ID on its own retry, so it is also
//! the resume position. Nothing here asks for it; the browser reads it off the frames.

const std = @import("std");

/// The event kinds the server names. `unknown` is not an error: a server that grows a new event type
/// must not break a client that has not learned it yet, so it is recorded and ignored.
pub const Kind = enum { hello, settings_changed, background_changed, preset_changed, worldinfo_changed, chat_changed, character_changed, backend_status, unknown };

pub fn kindFromName(name: []const u8) Kind {
    if (std.mem.eql(u8, name, "hello")) return .hello;
    if (std.mem.eql(u8, name, "settings-changed")) return .settings_changed;
    if (std.mem.eql(u8, name, "background-changed")) return .background_changed;
    if (std.mem.eql(u8, name, "preset-changed")) return .preset_changed;
    if (std.mem.eql(u8, name, "worldinfo-changed")) return .worldinfo_changed;
    if (std.mem.eql(u8, name, "chat-changed")) return .chat_changed;
    if (std.mem.eql(u8, name, "character-changed")) return .character_changed;
    if (std.mem.eql(u8, name, "backend-status")) return .backend_status;
    return .unknown;
}

pub const Event = struct {
    id: u32,
    kind: Kind,
    /// Borrowed for the duration of the call: the door frees its buffer when the export returns.
    data: []const u8,
};

const Counters = struct {
    total: u32 = 0,
    last_id: u32 = 0,
    connection_id: u32 = 0,
    hellos: u32 = 0,
    unknown: u32 = 0,
    /// Events whose id is not greater than the highest already seen, ie a resume replaying what the
    /// client had before the drop. Counted, never rejected: the router decides what to skip.
    replayed: u32 = 0,
};

var counters: Counters = .{};

pub fn stats() Counters {
    return counters;
}

/// The last id delivered. The browser sends this back as Last-Event-ID by itself; this copy exists
/// so the client can say what it has, not so it can drive the retry.
pub fn lastId() u32 {
    return counters.last_id;
}

pub fn reset() void {
    counters = .{};
}

/// One event, already parsed out of the frame by the glue. Returns the event so a caller can route
/// it; recording happens here so the count is the same whoever consumes it.
pub fn accept(id: u32, name: []const u8, data: []const u8) Event {
    const kind = kindFromName(name);
    counters.total += 1;
    if (kind == .unknown) counters.unknown += 1;
    if (kind == .hello) {
        counters.hellos += 1;
        counters.connection_id = parseConnectionId(data) orelse counters.connection_id;
    }
    if (id > 0) {
        if (id <= counters.last_id) counters.replayed += 1;
        if (id > counters.last_id) counters.last_id = id;
    }
    return .{ .id = id, .kind = kind, .data = data };
}

/// The connectionId out of a `hello` payload. The visibility beacon cannot be sent before this
/// arrives: the server keys visibility by connection, and posting an unknown id answers 404.
fn parseConnectionId(data: []const u8) ?u32 {
    const key = "\"connectionId\":";
    const at = std.mem.indexOf(u8, data, key) orelse return null;
    var i = at + key.len;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) i += 1;
    const start = i;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u32, data[start..i], 10) catch null;
}

pub fn connectionId() u32 {
    return counters.connection_id;
}

test "kind_from_name_maps_every_named_event_and_files_the_rest_as_unknown" {
    try std.testing.expectEqual(Kind.hello, kindFromName("hello"));
    try std.testing.expectEqual(Kind.settings_changed, kindFromName("settings-changed"));
    try std.testing.expectEqual(Kind.backend_status, kindFromName("backend-status"));
    try std.testing.expectEqual(Kind.unknown, kindFromName("something-the-server-grew-later"));
    try std.testing.expectEqual(Kind.unknown, kindFromName(""));
}

test "accept_records_the_id_so_a_router_can_dedupe_a_replay" {
    reset();
    _ = accept(1, "settings-changed", "{}");
    _ = accept(2, "settings-changed", "{}");
    try std.testing.expectEqual(@as(u32, 2), stats().total);
    try std.testing.expectEqual(@as(u32, 2), lastId());
    try std.testing.expectEqual(@as(u32, 0), stats().replayed);

    // A resume replays what the client already had; the ids do not advance and that is not an error.
    _ = accept(1, "settings-changed", "{}");
    _ = accept(2, "settings-changed", "{}");
    try std.testing.expectEqual(@as(u32, 2), lastId());
    try std.testing.expectEqual(@as(u32, 2), stats().replayed);
    try std.testing.expectEqual(@as(u32, 4), stats().total);

    _ = accept(3, "settings-changed", "{}");
    try std.testing.expectEqual(@as(u32, 3), lastId());
    try std.testing.expectEqual(@as(u32, 2), stats().replayed);
}

test "hello_carries_the_connection_id_the_visibility_beacon_needs" {
    reset();
    try std.testing.expectEqual(@as(u32, 0), connectionId());
    const ev = accept(0, "hello", "{\"connectionId\": 7, \"resumedFrom\": 0}");
    try std.testing.expectEqual(Kind.hello, ev.kind);
    try std.testing.expectEqual(@as(u32, 7), connectionId());
    try std.testing.expectEqual(@as(u32, 1), stats().hellos);
    // hello carries no id, so it must not move the resume position.
    try std.testing.expectEqual(@as(u32, 0), lastId());
}

test "a_hello_without_a_connection_id_leaves_the_last_known_one_alone" {
    reset();
    _ = accept(0, "hello", "{\"connectionId\":4}");
    _ = accept(0, "hello", "{}");
    try std.testing.expectEqual(@as(u32, 4), connectionId());
    try std.testing.expectEqual(@as(u32, 2), stats().hellos);
}

test "an_unnamed_event_is_counted_as_unknown_rather_than_dropped" {
    reset();
    _ = accept(9, "", "{}");
    try std.testing.expectEqual(@as(u32, 1), stats().unknown);
    try std.testing.expectEqual(@as(u32, 1), stats().total);
    try std.testing.expectEqual(@as(u32, 9), lastId());
}
