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
const reader = @import("./reader.zig");
const net = @import("./net.zig");
const regions = @import("./regions.zig");
const char_api = @import("./char_api.zig");
const group_send = @import("./group_send.zig");
const char_data = @import("./char_data.zig");

const log = std.log.scoped(.stream);
const gpa = store.page_gpa;

/// The single live stream. `begin` refuses a second while one runs, so one session covers solo, group
/// (sequential members) and the dev pair (sequential streams).
pub var live: stream_mod.Stream = .{ .allocator = store.page_gpa, .store = &store.global };

/// Both js.global.call sites use the same id; there is only ever one stream, but the door keys its map
/// on it so the shape already supports a second if one is ever needed.
const stream_id: f64 = 1;

const Kind = enum { send, dev };

const Session = struct {
    active: bool = false,
    kind: Kind = .send,
    /// True once the door has registered the stream (openDoor succeeded). Before this a cancel cannot
    /// reach the door op, so cancel() seals via the cancelled flag instead of a no-op door call.
    door_open: bool = false,
    /// Set by cancel() when a stop lands during the cold-csrf round-trip (before door_open); read by
    /// dispatchDoor to seal the begun message rather than open the stream the user already stopped.
    cancelled: bool = false,
    /// Bytes arrived from the door and not yet fed, drained once per animation frame.
    pending: std.ArrayList(u8) = .empty,
    scheduled: bool = false,
    /// True only while `flushFrame` is inside `live.feed`, read by env.sanitize (via
    /// __st_stream_rendering) to skip-highlight the still-growing last code block.
    flushing: bool = false,
    url: []u8 = &.{},
    body: []u8 = &.{},
    chunks: usize = 0,
    flushes: usize = 0,
};

var s: Session = .{};

// ---- production send path ----------------------------------------------------------------------

/// Opens a generation stream: appends the assistant message, then POSTs the prompt and pumps the SSE
/// reply into it. `name`/`avatar`/`body` are borrowed; this dupes what it keeps. Refuses a second
/// concurrent stream rather than aliasing the first's tail.
pub fn send(url: []const u8, name: []const u8, avatar: []const u8, body: []const u8) void {
    if (zx.platform.role != .client) return;
    if (!open(.send, name, avatar)) return;
    if (!stashRequest(url, body)) {
        abortOpen();
        return;
    }
    // The POST needs a csrf token; net.zig fetches one first if the cache is cold, then opens the door.
    net.ensureCsrfThen(dispatchDoor);
}

/// Abort the in-flight reply and seal what already arrived. The door aborts the reader, the loop ends,
/// and __st_stream_closed runs the normal seal.
pub fn cancel() void {
    if (zx.platform.role != .client) return;
    if (!s.active) return;
    if (!s.door_open) {
        // Stop arrived before the door registered the stream (cold-csrf round-trip): the door cancel
        // op would no-op on an unknown id, so flag it and let dispatchDoor seal instead of opening.
        s.cancelled = true;
        return;
    }
    js.global.call(void, "__st_stream_cancel", .{stream_id}) catch {
        log.warn("stop: __st_stream_cancel door op missing", .{});
    };
}

fn dispatchDoor() void {
    if (s.cancelled) {
        // The user stopped during the csrf round-trip: run the single seal path with a non-2xx status
        // so a group send tells its rotation (onStreamFailed) instead of the stream running on regardless.
        __st_stream_closed(0);
        return;
    }
    const csrf = net.currentCsrf() orelse "";
    openDoor(s.url, s.body, csrf);
}

fn openDoor(url: []const u8, body: []const u8, csrf: []const u8) void {
    js.global.call(void, "__st_stream_open", .{
        stream_id,
        js.string(url),
        js.string(body),
        js.string(csrf),
    }) catch {
        log.err("send: __st_stream_open door op missing", .{});
        __st_stream_closed(0);
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
    reader.__st_reader_stream_begin();
    live.begin(name_c, avatar_c) catch |err| {
        gpa.free(name_c);
        gpa.free(avatar_c);
        log.err("stream open: {s}, stream not started", .{@errorName(err)});
        reader.__st_reader_stream_end();
        return false;
    };
    s = .{ .active = true, .kind = kind };
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
    reader.__st_reader_stream_end();
    resetSession();
}

// ---- door -> Zig callbacks ---------------------------------------------------------------------

/// One raw SSE chunk from the door pump. Door-allocated; copied into the pending batch and freed.
pub export fn __st_stream_chunk(ptr: usize, len: usize) callconv(.c) void {
    if (ptr == 0 or len == 0) return;
    const buf = @as([*]u8, @ptrFromInt(ptr))[0..len];
    // Free the door allocation on every path, including the defensive drop below.
    defer gpa.free(buf);
    if (!s.active) return;
    s.pending.appendSlice(gpa, buf) catch {
        log.err("stream chunk dropped: out of memory batching", .{});
        return;
    };
    s.chunks += 1;
    schedule();
}

/// The reader ended: natural close, network error, or a cancel we drove. Fires exactly once per
/// stream, so it is the single seal point.
pub export fn __st_stream_closed(status: u32) callconv(.c) void {
    if (!s.active) return;
    // Whatever the rAF cadence left unfed must still reach the message before it seals.
    flushPending();
    live.end();
    reader.__st_reader_stream_end();
    regions.bumpMessageLog();

    const dev_metrics = s.kind == .dev;
    const kind = s.kind;
    // A spun-down .43 behind Pocket-ID answers 502/504 at the edge before ST is reached.
    if (status == 502 or status == 504) setSendStatus("Backend asleep - unlock at silly");
    // Seal the highlight + fill the dev metrics block (held hljs, so JS owns the how, Zig the when).
    js.global.call(void, "__st_stream_sealed", .{@as(f64, if (dev_metrics) 1 else 0)}) catch {};

    resetSession();

    switch (kind) {
        .send => if (status >= 200 and status < 300) char_api.persistNewTurns() else group_send.onStreamFailed(),
        .dev => runNextDev(),
    }
}

/// True while a flush feed is in progress: env.sanitize reads this to leave the growing last code
/// block un-highlighted until the stream seals, matching the old JS streamRender flag.
pub export fn __st_stream_rendering() callconv(.c) u32 {
    return @intFromBool(s.flushing);
}

pub export fn __st_stream_tokens() callconv(.c) usize {
    return live.tokens;
}

pub export fn __st_stream_chunks() callconv(.c) usize {
    return s.chunks;
}

pub export fn __st_stream_flushes() callconv(.c) usize {
    return s.flushes;
}

// ---- rAF flush batching ------------------------------------------------------------------------

fn schedule() void {
    if (s.scheduled) return;
    s.scheduled = true;
    _ = zx.client.requestAnimationFrame(flushFrame);
}

/// Coalesces a frame's worth of chunks into one feed and one render, so a burst of network chunks is
/// one visible update, not one per chunk.
fn flushFrame() void {
    s.scheduled = false;
    if (!s.active) return;
    flushPending();
    reader.__st_reader_stream_tick();
    // A [DONE] sentinel sealed the stream mid-feed: stop the door reader now rather than wait for the
    // socket to close on its own.
    if (live.state == .done) cancel();
}

fn flushPending() void {
    if (s.pending.items.len == 0) return;
    s.flushing = true;
    live.feed(s.pending.items) catch |err| {
        log.err("stream feed: {s}, stream sealed early", .{@errorName(err)});
        live.end();
    };
    s.flushing = false;
    s.pending.clearRetainingCapacity();
    s.flushes += 1;
    regions.bumpMessageLog();
}

fn resetSession() void {
    if (s.url.len > 0) gpa.free(s.url);
    if (s.body.len > 0) gpa.free(s.body);
    s.pending.clearAndFree(gpa);
    s = .{};
}

fn setSendStatus(text: []const u8) void {
    const doc = js.global.get(js.Object, "document") catch return;
    defer doc.deinit();
    const el = (doc.call(?js.Object, "getElementById", .{js.string("send-status")}) catch return) orelse return;
    defer el.deinit();
    el.set("textContent", js.string(text)) catch {};
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
