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
pub const Kind = enum { hello, resync, settings_changed, background_changed, preset_changed, worldinfo_changed, chat_changed, chat_appended, character_changed, backend_status, unknown };

pub fn kindFromName(name: []const u8) Kind {
    if (std.mem.eql(u8, name, "hello")) return .hello;
    if (std.mem.eql(u8, name, "resync")) return .resync;
    if (std.mem.eql(u8, name, "settings-changed")) return .settings_changed;
    if (std.mem.eql(u8, name, "background-changed")) return .background_changed;
    if (std.mem.eql(u8, name, "preset-changed")) return .preset_changed;
    if (std.mem.eql(u8, name, "worldinfo-changed")) return .worldinfo_changed;
    if (std.mem.eql(u8, name, "chat-changed")) return .chat_changed;
    if (std.mem.eql(u8, name, "chat-appended")) return .chat_appended;
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
    /// client had before the drop. Counted and NOT routed: the refresh already ran the first time.
    replayed: u32 = 0,
    /// Events that reached a route. total minus this is what the dedupe and the empty routes absorbed.
    applied: u32 = 0,
};

/// Whether a stream is currently carrying events. The poll reads this and REFUSES to arm while it is
/// true: the settings load arms the poll unconditionally and lands after the hello, so without this
/// the channel and its fallback both run, and every settings change re-arms the one just stood down.
var stream_live: bool = false;

pub fn streamLive() bool {
    return stream_live;
}

/// Where each event type lands. Optional pointers rather than direct imports: this module is
/// zx-free so it can join `zig build test`, and the subsystems it drives are not.
pub const Routes = struct {
    settings: ?*const fn () void = null,
    background: ?*const fn () void = null,
    preset: ?*const fn () void = null,
    worldinfo: ?*const fn () void = null,
    chat: ?*const fn () void = null,
    /// Handed the raw payload: the appended messages ride the event, so this is the one route that
    /// does not refetch.
    chat_append: ?*const fn ([]const u8) void = null,
    character: ?*const fn () void = null,
    backend_status: ?*const fn ([]const u8) void = null,
    /// The resume window overflowed, so the server could not replay what this client missed and
    /// says so instead of pretending. Everything must be refetched; nothing else can close the gap.
    resync: ?*const fn () void = null,
    /// The stream is live (a hello landed), so the standalone poll can stand down.
    stream_up: ?*const fn () void = null,
    /// The stream dropped, so the poll takes the status back over until the next hello.
    stream_down: ?*const fn () void = null,
};

var routes: Routes = .{};

pub fn setRoutes(r: Routes) void {
    routes = r;
}

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
    routes = .{};
    stream_live = false;
}

/// One event, already parsed out of the frame by the glue. Returns the event so a caller can route
/// it; recording happens here so the count is the same whoever consumes it.
pub fn accept(id: u32, name: []const u8, data: []const u8) Event {
    const kind = kindFromName(name);
    const ev: Event = .{ .id = id, .kind = kind, .data = data };
    counters.total += 1;
    if (kind == .unknown) counters.unknown += 1;
    if (kind == .hello) {
        counters.hellos += 1;
        counters.connection_id = parseConnectionId(data) orelse counters.connection_id;
        stream_live = true;
        if (routes.stream_up) |f| f();
        return ev;
    }
    if (id > 0) {
        // A resume replays what the client already applied, so the second sighting must not refresh
        // again. The id is the only thing that can tell them apart.
        if (id <= counters.last_id) {
            counters.replayed += 1;
            return ev;
        }
        counters.last_id = id;
    }
    route(ev);
    return ev;
}

/// The stream dropped. Not an event: the browser reports it, and the poll has to take over before
/// the next hello, or the status goes stale for the length of the retry.
pub fn streamDown() void {
    stream_live = false;
    if (routes.stream_down) |f| f();
}

fn route(ev: Event) void {
    const hit: ?*const fn () void = switch (ev.kind) {
        .settings_changed => routes.settings,
        .background_changed => routes.background,
        .preset_changed => routes.preset,
        .worldinfo_changed => routes.worldinfo,
        .chat_changed => routes.chat,
        .resync => routes.resync,
        .character_changed => routes.character,
        .chat_appended => {
            if (routes.chat_append) |f| {
                counters.applied += 1;
                f(ev.data);
            }
            return;
        },
        .backend_status => {
            if (routes.backend_status) |f| {
                counters.applied += 1;
                f(ev.data);
            }
            return;
        },
        .hello, .unknown => null,
    };
    if (hit) |f| {
        counters.applied += 1;
        f();
    }
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

/// This tab's origin tag. It goes out on the stream URL as `?clientId=` and on every mutation as
/// `X-ST-Client-Id`, and the server compares the two to skip echoing a write back to its author.
/// Both halves must be the SAME string or the tab refetches on its own every write.
var client_id_buf: [64]u8 = undefined;
var client_id_len: usize = 0;

pub fn setClientId(id: []const u8) void {
    const n = @min(id.len, client_id_buf.len);
    @memcpy(client_id_buf[0..n], id[0..n]);
    client_id_len = n;
}

pub fn clientId() []const u8 {
    return client_id_buf[0..client_id_len];
}

var t_settings: u32 = 0;
var t_chat: u32 = 0;
var t_append: u32 = 0;
var t_append_last: []const u8 = "";
var t_up: u32 = 0;
var t_down: u32 = 0;

fn tSettings() void {
    t_settings += 1;
}
fn tChat() void {
    t_chat += 1;
}
fn tAppend(data: []const u8) void {
    t_append += 1;
    t_append_last = data;
}
fn tUp() void {
    t_up += 1;
}
fn tDown() void {
    t_down += 1;
}

fn testRoutes() void {
    reset();
    t_settings = 0;
    t_chat = 0;
    t_append = 0;
    t_append_last = "";
    t_up = 0;
    t_down = 0;
    setRoutes(.{
        .settings = tSettings,
        .chat = tChat,
        .chat_append = tAppend,
        .stream_up = tUp,
        .stream_down = tDown,
    });
}

test "each_event_type_reaches_its_own_route_and_nothing_else" {
    testRoutes();
    _ = accept(1, "settings-changed", "{}");
    try std.testing.expectEqual(@as(u32, 1), t_settings);
    try std.testing.expectEqual(@as(u32, 0), t_chat);

    _ = accept(2, "chat-changed", "{}");
    try std.testing.expectEqual(@as(u32, 1), t_settings);
    try std.testing.expectEqual(@as(u32, 1), t_chat);
    try std.testing.expectEqual(@as(u32, 2), stats().applied);
}

test "a_replayed_batch_refreshes_once_not_twice" {
    testRoutes();
    _ = accept(1, "settings-changed", "{}");
    _ = accept(2, "chat-changed", "{}");
    _ = accept(3, "settings-changed", "{}");
    try std.testing.expectEqual(@as(u32, 2), t_settings);
    try std.testing.expectEqual(@as(u32, 1), t_chat);

    // The resume: the same three arrive again because the reconnect is the browser's.
    _ = accept(1, "settings-changed", "{}");
    _ = accept(2, "chat-changed", "{}");
    _ = accept(3, "settings-changed", "{}");
    try std.testing.expectEqual(@as(u32, 2), t_settings);
    try std.testing.expectEqual(@as(u32, 1), t_chat);
    try std.testing.expectEqual(@as(u32, 3), stats().replayed);
    try std.testing.expectEqual(@as(u32, 3), stats().applied);

    // An id past the high-water mark is new work, replay or not.
    _ = accept(4, "chat-changed", "{}");
    try std.testing.expectEqual(@as(u32, 2), t_chat);
}

test "the_appended_messages_ride_the_event_rather_than_triggering_a_refetch" {
    testRoutes();
    _ = accept(1, "chat-appended", "{\"card\":\"Seraphina\",\"messages\":[{\"mes\":\"hi\"}]}");
    try std.testing.expectEqual(@as(u32, 1), t_append);
    try std.testing.expectEqual(@as(u32, 0), t_chat);
    try std.testing.expect(std.mem.indexOf(u8, t_append_last, "Seraphina") != null);
}

test "a_hello_stands_the_poll_down_and_a_drop_hands_it_back" {
    testRoutes();
    _ = accept(0, "hello", "{\"connectionId\":3}");
    try std.testing.expectEqual(@as(u32, 1), t_up);
    try std.testing.expectEqual(@as(u32, 0), t_down);

    streamDown();
    try std.testing.expectEqual(@as(u32, 1), t_down);

    // The reconnect's hello stands it down again, so a flapping stream cannot leave both running.
    _ = accept(0, "hello", "{\"connectionId\":4}");
    try std.testing.expectEqual(@as(u32, 2), t_up);
    try std.testing.expectEqual(@as(u32, 4), connectionId());
}

test "the_client_id_is_one_string_so_the_stream_and_the_mutations_agree" {
    reset();
    try std.testing.expectEqual(@as(usize, 0), clientId().len);
    setClientId("c-4f2a91");
    try std.testing.expectEqualStrings("c-4f2a91", clientId());
}

test "kind_from_name_maps_every_named_event_and_files_the_rest_as_unknown" {
    try std.testing.expectEqual(Kind.hello, kindFromName("hello"));
    try std.testing.expectEqual(Kind.settings_changed, kindFromName("settings-changed"));
    try std.testing.expectEqual(Kind.backend_status, kindFromName("backend-status"));
    try std.testing.expectEqual(Kind.chat_appended, kindFromName("chat-appended"));
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
