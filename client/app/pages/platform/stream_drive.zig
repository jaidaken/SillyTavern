//! The Zig-owned SSE streaming orchestrator. Owns the whole send-to-seal lifecycle that used to live
//! in glue/custom.js (startStream / __st_send_stream / __st_send_stop): it opens the door getReader
//! pump (D10) via js.global.call, batches the arriving chunks on requestAnimationFrame, drives the
//! cancel, sources the csrf token from net.zig, and seals through the Stream state machine.
//!
//! The ONLY streaming code left in JS is the door pump (a genuine browser IO: zx.fetch cannot stream)
//! and the held DOMPurify+hljs sanitize/seal-highlight, which Zig calls into per render and once at
//! seal. Framing, batching, lifecycle, cancel and csrf are all here.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const store = @import("./store.zig");
const stream_mod = @import("./stream.zig");
const reader = @import("../chat/reader.zig");
const net = @import("./net.zig");
const regions = @import("../shell/regions.zig");
const connection = @import("../setup/connection.zig");
const char_api = @import("../cast/char_api.zig");
const group_send = @import("../cast/group_send.zig");
const char_data = @import("../cast/char_data.zig");
const html = @import("./html.zig");

const log = std.log.scoped(.stream);
const gpa = store.page_gpa;

/// The single live stream. `begin` refuses a second while one runs, so one session covers solo, group
/// (sequential members) and the dev pair (sequential streams).
pub var live: stream_mod.Stream = .{ .allocator = store.page_gpa, .store = &store.global };

/// Every stream gets its own door id. Sealing on `[DONE]` ends a session while its door reader is
/// still unwinding, so the next stream can open before the old one's close callback lands; a shared
/// id would let that stale callback seal the new stream the moment it began.
var stream_seq: f64 = 0;

const Kind = enum { send, dev };

/// Backoff before a re-attach, and the ceiling on how many a single generation may spend. A drop that
/// keeps repeating is a server that is gone, not a flapping socket, so the message seals instead.
const reattach_delay_ms: u32 = 400;
const max_reattach: u8 = 5;

const Session = struct {
    active: bool = false,
    kind: Kind = .send,
    /// This session's door id. Zero when no session is running, which no live door stream ever uses.
    id: f64 = 0,
    /// True once the door has registered the stream (openDoor succeeded). Before this a cancel cannot
    /// reach the door op, so cancel() seals via the cancelled flag instead of a no-op door call.
    door_open: bool = false,
    /// Set by cancel() when a stop lands before the door is open; read by the start callback to seal
    /// the begun message rather than open a stream the user already stopped.
    cancelled: bool = false,
    /// True from the moment a stop is requested: a close that follows one is the end of the
    /// generation, never a transport drop to re-attach to.
    stopping: bool = false,
    /// The server-issued generation id. Empty for a dev stream, which the server does not own.
    generation_id: []u8 = &.{},
    reattaches: u8 = 0,
    /// Bytes arrived from the door and not yet fed, drained on every chunk.
    pending: std.ArrayList(u8) = .empty,
    scheduled: bool = false,
    /// True only while a feed is inside `live.feed`, read by env.sanitize (via
    /// __st_stream_rendering) to skip-highlight the still-growing last code block.
    flushing: bool = false,
    url: []u8 = &.{},
    body: []u8 = &.{},
    chunks: usize = 0,
    /// Renders, not feeds: the gate row asserts one visible update per frame, so this counts the
    /// rAF-paced bumpMessageLog calls, never the per-chunk decoder feeds.
    flushes: usize = 0,
};

var s: Session = .{};

/// The last generation this page rendered to completion. Held past the session so the server's
/// chat-appended for that reply can be recognised as one this page already has.
var sealed_generation: []u8 = &.{};

/// Whether a stream is actually in progress. The Stream's own state is not the test: it rests in
/// `.done` between the reply sealing and the session being torn down, and a send offered there is
/// perfectly fine to accept.
pub fn busy() bool {
    return s.active;
}

/// Whether this page has already rendered the generation named by `id`, live or sealed.
pub fn renderedGeneration(id: []const u8) bool {
    if (id.len == 0) return false;
    if (s.active and s.generation_id.len > 0 and std.mem.eql(u8, s.generation_id, id)) return true;
    return sealed_generation.len > 0 and std.mem.eql(u8, sealed_generation, id);
}

// ---- production send path ----------------------------------------------------------------------

/// Starts a server-owned generation: appends the assistant message, then POSTs the prompt to the
/// start route. The reply carries the generation id, and the door pump attaches to its stream.
/// `name`/`avatar`/`start_body` are borrowed; this dupes what it keeps. Refuses a second concurrent
/// stream rather than aliasing the first's tail.
pub fn send(name: []const u8, avatar: []const u8, start_body: []const u8) void {
    if (zx.platform.role != .client) return;
    if (!open(.send, name, avatar)) return;
    if (!stashRequest("/api/generation/start", start_body)) {
        abortOpen();
        return;
    }
    // retry_403 stays off: a blind retry of a start would run the generation twice.
    net.request(s.url, s.body, 0, onStartDone, .{ .retry_403 = false });
}

/// Attaches to a generation the server is already running, rebuilding the reply from the frame log.
/// Used when a page loads onto a chat whose generation is still in flight.
pub fn attach(generation_id: []const u8, name: []const u8, avatar: []const u8) void {
    if (zx.platform.role != .client) return;
    if (generation_id.len == 0) return;
    if (!open(.send, name, avatar)) return;
    setOwned(&s.generation_id, generation_id);
    if (s.generation_id.len == 0) {
        abortOpen();
        return;
    }
    // Cursor 0: this page holds no tokens yet, so the whole frame log is replayed into the message.
    openStreamDoor(0);
}

/// Stop the generation for real. The server owns it now, so a stop is a request to the server, not
/// just a local reader cancel: closing the door alone would leave the model running.
pub fn cancel() void {
    if (zx.platform.role != .client) return;
    if (!s.active) return;
    s.stopping = true;
    if (s.generation_id.len > 0) {
        const url = std.fmt.allocPrint(gpa, "/api/generation/{s}/stop", .{s.generation_id}) catch {
            log.err("stop: could not build the stop url", .{});
            return;
        };
        defer gpa.free(url);
        net.request(url, "{}", 0, onStopDone, .{ .retry_403 = false });
    }
    if (!s.door_open) {
        // Stop arrived before the door registered the stream: the door cancel op would no-op on an
        // unknown id, so flag it and let the start callback seal instead of opening.
        s.cancelled = true;
        return;
    }
    js.global.call(void, "__st_stream_cancel", .{s.id}) catch {
        log.warn("stop: __st_stream_cancel door op missing", .{});
    };
}

/// Give up watching, WITHOUT stopping the generation. Called when the store is replaced under a live
/// stream (a 409 re-sync, or the reader reloading the chat): the message being fed no longer exists,
/// so feeding it further is writing into nothing. The server keeps generating and the chat re-open
/// that follows re-attaches through checkActiveGeneration, rebuilding the reply from the frame log.
pub fn detach() void {
    if (zx.platform.role != .client) return;
    if (!s.active) return;
    if (s.door_open) {
        js.global.call(void, "__st_stream_cancel", .{s.id}) catch {};
    }
    live.end();
    live.state = .idle;
    reader.streamEnd();
    if (s.generation_id.len > 0) setOwned(&sealed_generation, s.generation_id);
    resetSession();
    regions.bumpMessageLog();
}

fn onStopDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (status < 200 or status >= 300) {
        log.warn("stop: the server refused the stop ({d}); the generation may still be running", .{status});
    }
}

fn onStartDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (!s.active) return;
    if (s.cancelled) {
        // The user stopped during the start round-trip: run the single seal path with a non-2xx status
        // so a group send tells its rotation (onStreamFailed) instead of running on regardless.
        __st_stream_closed(s.id, 0);
        return;
    }
    const r = res orelse {
        __st_stream_closed(s.id, 0);
        return;
    };
    // 409 means the server is already running a generation for this chat. The server owns it, so the
    // right move is to watch that one rather than drop the message this page has already begun.
    if (status != 409 and (status < 200 or status >= 300)) {
        log.warn("send: the server refused the generation start ({d})", .{status});
        __st_stream_closed(s.id, status);
        return;
    }
    const parsed = r.json(struct { generation_id: []const u8 = "", last_event_id: ?i64 = null }) catch {
        log.err("send: the start reply did not parse", .{});
        __st_stream_closed(s.id, 0);
        return;
    };
    defer parsed.deinit();
    if (parsed.value.generation_id.len == 0) {
        log.err("send: the start reply carried no generation id", .{});
        __st_stream_closed(s.id, 0);
        return;
    }
    setOwned(&s.generation_id, parsed.value.generation_id);
    if (s.generation_id.len == 0) {
        __st_stream_closed(s.id, 0);
        return;
    }
    openStreamDoor(0);
}

/// Opens the door pump on the generation's stream route at `cursor`. The cursor rides the query
/// because the door builds a fixed header set and cannot send Last-Event-ID.
fn openStreamDoor(cursor: u64) void {
    const url = std.fmt.allocPrint(gpa, "/api/generation/{s}/stream?since={d}", .{ s.generation_id, cursor }) catch {
        log.err("send: could not build the stream url", .{});
        __st_stream_closed(s.id, 0);
        return;
    };
    defer gpa.free(url);
    // A GET carries no csrf; the door picks GET on an empty body.
    openDoor(url, "", "");
}

fn setOwned(slot: *[]u8, value: []const u8) void {
    if (slot.len > 0) gpa.free(slot.*);
    slot.* = gpa.dupe(u8, value) catch &.{};
}

fn openDoor(url: []const u8, body: []const u8, csrf: []const u8) void {
    js.global.call(void, "__st_stream_open", .{
        s.id,
        js.string(url),
        js.string(body),
        js.string(csrf),
    }) catch {
        log.err("send: __st_stream_open door op missing", .{});
        __st_stream_closed(s.id, 0);
        return;
    };
    s.door_open = true;
}

// ---- shared open/seal --------------------------------------------------------------------------

/// Begins the Stream (appends the assistant message) and marks the session active. False if a stream
/// is already running or the store refuses the message; on false the caller must not proceed.
fn open(kind: Kind, name: []const u8, avatar: []const u8) bool {
    if (s.active) {
        log.warn("stream open refused: a stream is already running", .{});
        return false;
    }
    const name_c = gpa.dupe(u8, name) catch return false;
    const avatar_c = gpa.dupe(u8, avatar) catch {
        gpa.free(name_c);
        return false;
    };
    // reader owns the follow decision (pin if this send forced it or you were near the bottom).
    reader.streamBegin();
    live.begin(name_c, avatar_c) catch |err| {
        gpa.free(name_c);
        gpa.free(avatar_c);
        log.err("stream open: {s}, stream not started", .{@errorName(err)});
        reader.streamEnd();
        return false;
    };
    stream_seq += 1;
    s = .{ .active = true, .kind = kind, .id = stream_seq };
    regions.bumpMessageLog();
    return true;
}

fn stashRequest(url: []const u8, body: []const u8) bool {
    s.url = gpa.dupe(u8, url) catch return false;
    s.body = gpa.dupe(u8, body) catch {
        gpa.free(s.url);
        s.url = &.{};
        return false;
    };
    return true;
}

/// Unwind an open() that could not complete (request stash OOM): seal the just-begun message so it is
/// not stranded in .streaming, and clear the session.
fn abortOpen() void {
    live.end();
    live.state = .idle;
    reader.streamEnd();
    resetSession();
}

// ---- door -> Zig callbacks ---------------------------------------------------------------------

/// One raw SSE chunk from the door pump. Door-allocated; copied into the pending batch and freed.
/// The decoder is fed eagerly here (a background tab gets no animation frames), but the render stays
/// on the rAF path so a burst of chunks is still one visible update.
pub export fn __st_stream_chunk(door_stream_id: f64, ptr: usize, len: usize) callconv(.c) void {
    if (ptr == 0 or len == 0) return;
    const buf = @as([*]u8, @ptrFromInt(ptr))[0..len];
    // Free the door allocation on every path, including the defensive drops below.
    defer gpa.free(buf);
    if (!s.active) return;
    if (door_stream_id != s.id) return;
    s.pending.appendSlice(gpa, buf) catch {
        log.err("stream chunk dropped: out of memory batching", .{});
        return;
    };
    s.chunks += 1;
    feedPending();
    if (sealIfDone()) return;
    schedule();
}

/// `[DONE]` is the end of the GENERATION, so seal on it rather than waiting for the transport to
/// close. The door's close is a round trip behind the sentinel now that the server owns the stream,
/// and a send offered in that window would be refused with the reply already looking finished.
fn sealIfDone() bool {
    if (!s.active or live.state != .done) return false;
    if (s.door_open) {
        js.global.call(void, "__st_stream_cancel", .{s.id}) catch {};
    }
    __st_stream_closed(s.id, 200);
    return true;
}

/// The reader ended: natural close, network error, or a cancel we drove. A close is NOT proof the
/// generation ended: the server owns it now, so a close with no `[DONE]` and no stop behind it is a
/// dropped transport, and the session re-attaches at its cursor instead of sealing a partial reply.
pub export fn __st_stream_closed(door_stream_id: f64, status: u32) callconv(.c) void {
    if (!s.active) return;
    if (door_stream_id != s.id) return;
    s.door_open = false;
    // Whatever the frame cadence left unfed must still reach the message.
    renderPending();

    if (transportDropped(status) and beginReattach()) return;

    live.end();
    live.state = .idle;
    reader.streamEnd();
    regions.bumpMessageLog();

    const dev_metrics = s.kind == .dev;
    const kind = s.kind;
    // A spun-down .43 behind Pocket-ID answers 502/504 at the edge before ST is reached. The
    // readout is connection.zig's to own now, so this reports the fact and lets it hold the state.
    if (status == 502 or status == 504) connection.onStreamUnreachable();
    // Seal the highlight (held hljs, so JS owns the how, Zig the when); the dev metrics block is now
    // filled Zig-side below, so JS is left with nothing but the hljs call.
    js.global.call(void, "__st_stream_sealed", .{}) catch {};
    if (dev_metrics) writeProbeMetrics();

    if (s.generation_id.len > 0) setOwned(&sealed_generation, s.generation_id);
    resetSession();

    switch (kind) {
        .send => {
            // The server wrote the reply; the seal only settles client-side state and advances a
            // group rotation.
            char_api.onStreamSealed();
            if (status < 200 or status >= 300) group_send.onStreamFailed();
        },
        .dev => runNextDev(),
    }
}

/// Whether this close is a transport drop under a generation the server still owns, rather than the
/// end of the reply. `[DONE]` puts the Stream in `.done`, an explicit stop sets `stopping`, and a dev
/// stream has no server-side generation to go back to.
fn transportDropped(status: u32) bool {
    if (s.kind != .send) return false;
    if (s.generation_id.len == 0) return false;
    if (s.stopping or s.cancelled) return false;
    if (live.state == .done) return false;
    // A 404 means the server no longer holds this generation, so there is nothing to re-attach to.
    if (status == 404) return false;
    // 502/504 is the edge answering for a backend that is not there, so re-attaching cannot reach the
    // generation either: fall through and let the seal report it instead of spending the retry budget.
    if (status == 502 or status == 504) return false;
    return true;
}

/// Re-opens the door on the same generation at the client's cursor, after a short backoff. False when
/// the retry budget is spent, which routes the close back onto the normal seal path.
fn beginReattach() bool {
    if (s.reattaches >= max_reattach) {
        log.warn("stream: giving up re-attaching after {d} tries, sealing what arrived", .{s.reattaches});
        return false;
    }
    s.reattaches += 1;
    log.info("stream: transport dropped, re-attaching at cursor {d} (try {d})", .{ live.last_event_id, s.reattaches });
    _ = zx.client.setTimeout(reattachNow, reattach_delay_ms);
    return true;
}

fn reattachNow() void {
    if (!s.active or s.stopping or s.generation_id.len == 0) return;
    openStreamDoor(live.last_event_id);
}

/// True while a feed is in progress: env.sanitize reads this to leave the growing last code
/// block un-highlighted until the stream seals, matching the old JS streamRender flag.
pub export fn __st_stream_rendering() callconv(.c) u32 {
    return @intFromBool(s.flushing);
}

/// Fill the verify gate's #probe-metrics with the seal-time stream stats. Zig owns every field now
/// (chunks/flushes on the session, tokens on the Stream, sanitizes from html.zig), so the whole block
/// is built and written here rather than gathered back across the boundary by the JS seal glue. Reads
/// happen before resetSession, so the session counters are still live.
fn writeProbeMetrics() void {
    const doc = js.global.get(js.Object, "document") catch return;
    defer doc.deinit();
    const el = (doc.call(?js.Object, "getElementById", .{js.string("probe-metrics")}) catch return) orelse return;
    defer el.deinit();
    var buf: [192]u8 = undefined;
    const json = std.fmt.bufPrint(
        &buf,
        "{{\"chunks\":{d},\"tokens\":{d},\"flushes\":{d},\"sanitizes\":{d}}}",
        .{ s.chunks, live.tokens, s.flushes, html.sanitizes() },
    ) catch return;
    el.set("textContent", js.string(json)) catch {};
}

// ---- rAF flush batching ------------------------------------------------------------------------

fn schedule() void {
    if (s.scheduled) return;
    s.scheduled = true;
    _ = zx.client.requestAnimationFrame(flushFrame);
}

/// Coalesces a frame's worth of chunks into one render, so a burst of network chunks is one visible
/// update, not one per chunk. The decode already happened per chunk; only the render waits for here.
fn flushFrame() void {
    s.scheduled = false;
    if (!s.active) return;
    renderPending();
    reader.streamTick();
    _ = sealIfDone();
}

/// Decodes whatever arrived into the message. Runs per chunk so a background tab, which gets no
/// animation frames, still decodes as the bytes land.
fn feedPending() void {
    if (s.pending.items.len == 0) return;
    s.flushing = true;
    live.feed(s.pending.items) catch |err| {
        log.err("stream feed: {s}, stream sealed early", .{@errorName(err)});
        live.end();
    };
    s.flushing = false;
    s.pending.clearRetainingCapacity();
}

/// One visible update: drain anything still pending, then re-render the log exactly once.
fn renderPending() void {
    feedPending();
    s.flushes += 1;
    regions.bumpMessageLog();
}

fn resetSession() void {
    if (s.url.len > 0) gpa.free(s.url);
    if (s.body.len > 0) gpa.free(s.body);
    if (s.generation_id.len > 0) gpa.free(s.generation_id);
    s.pending.clearAndFree(gpa);
    s = .{};
}

// ---- dev stream driver (verify.sh ?stream= harness) --------------------------------------------

var dev_first_url: []u8 = &.{};
var dev_first_name: []u8 = &.{};
var dev_second_url: []u8 = &.{};
var dev_second_name: []u8 = &.{};
var dev_hold_ms: u32 = 0;

/// Called once from glue init: reads ?stream / ?hold and drives the dev streaming the verify gate
/// asserts on. ?stream=1 streams 200 tokens; ?stream=2 streams two sequential bodies; any other value
/// is a custom /dev/stream URL. No-op without ?stream, so a real load never touches this.
pub export fn __st_dev_stream_init() callconv(.c) void {
    if (zx.platform.role != .client) return;
    const search = locationSearch() orelse return;
    defer gpa.free(search);
    const raw = char_data.queryValue(search, "stream") orelse return;
    const param = percentDecode(raw) orelse return;
    defer gpa.free(param);

    dev_hold_ms = readHold(search);
    ensureProbeMetrics();

    if (std.mem.eql(u8, param, "1")) {
        setDev(&dev_first_url, &dev_first_name, "/dev/stream?n=200", "Seraphina");
    } else if (std.mem.eql(u8, param, "2")) {
        setDev(&dev_first_url, &dev_first_name, "/dev/stream?n=20&prefix=aaa", "First");
        setDev(&dev_second_url, &dev_second_name, "/dev/stream?n=20&prefix=bbb", "Second");
    } else if (isSameOriginPath(param)) {
        setDev(&dev_first_url, &dev_first_name, param, "Seraphina");
    } else {
        // Same-origin only: a crafted ?stream=https://attacker/sse would otherwise stream cross-origin
        // content into the chat. The verify harness only passes "/dev/stream...", so it is unaffected.
        log.warn("dev stream ignored: ?stream must be a same-origin path, not {s}", .{param});
        return;
    }
    if (dev_first_url.len == 0) return;
    if (dev_hold_ms == 0) devRun() else _ = zx.client.setTimeout(devRun, dev_hold_ms);
}

fn devRun() void {
    if (dev_first_url.len == 0) return;
    openDev(dev_first_url, dev_first_name);
    freeDevFirst();
}

fn runNextDev() void {
    if (dev_second_url.len == 0) return;
    dev_first_url = dev_second_url;
    dev_first_name = dev_second_name;
    dev_second_url = &.{};
    dev_second_name = &.{};
    devRun();
}

fn openDev(url: []const u8, name: []const u8) void {
    if (!open(.dev, name, "")) return;
    if (!stashRequest(url, "")) {
        abortOpen();
        return;
    }
    // Dev streams are GET with no csrf; open the door directly.
    openDoor(s.url, "", "");
}

fn setDev(url_slot: *[]u8, name_slot: *[]u8, url: []const u8, name: []const u8) void {
    url_slot.* = gpa.dupe(u8, url) catch &.{};
    name_slot.* = gpa.dupe(u8, name) catch &.{};
}

fn freeDevFirst() void {
    if (dev_first_url.len > 0) gpa.free(dev_first_url);
    if (dev_first_name.len > 0) gpa.free(dev_first_name);
    dev_first_url = &.{};
    dev_first_name = &.{};
}

fn readHold(search: []const u8) u32 {
    const raw = char_data.queryValue(search, "hold") orelse return 0;
    return std.fmt.parseInt(u32, raw, 10) catch 0;
}

/// A same-origin relative path starts with a single "/" (not "//", which is protocol-relative and
/// resolves cross-origin). The param is already percent-decoded, so "//" cannot hide behind an escape.
fn isSameOriginPath(url: []const u8) bool {
    return url.len >= 1 and url[0] == '/' and (url.len < 2 or url[1] != '/');
}

fn locationSearch() ?[]u8 {
    const loc = js.global.get(js.Object, "location") catch return null;
    defer loc.deinit();
    return loc.getAlloc(js.String, gpa, "search") catch null;
}

fn percentDecode(raw: []const u8) ?[]u8 {
    // Decode in a scratch copy, then dupe the shortened result so the returned slice's length matches
    // its allocation (a sub-slice of the scratch would mis-free).
    const scratch = gpa.dupe(u8, raw) catch return null;
    defer gpa.free(scratch);
    const decoded = std.Uri.percentDecodeInPlace(scratch);
    return gpa.dupe(u8, decoded) catch null;
}

/// The verify gate reads #probe-metrics as the seal signal; create it before the first token so the
/// seal write has a target. Idempotent.
fn ensureProbeMetrics() void {
    const doc = js.global.get(js.Object, "document") catch return;
    defer doc.deinit();
    const existing = doc.call(?js.Object, "getElementById", .{js.string("probe-metrics")}) catch null;
    if (existing) |e| {
        e.deinit();
        return;
    }
    const created = doc.call(?js.Object, "createElement", .{js.string("pre")}) catch return;
    const pre = created orelse return;
    defer pre.deinit();
    pre.set("id", js.string("probe-metrics")) catch {};
    const bodyEl = doc.get(js.Object, "body") catch return;
    defer bodyEl.deinit();
    _ = bodyEl.call(?js.Object, "appendChild", .{pre}) catch null;
}
