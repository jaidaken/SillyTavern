//! Zig-owned network layer: the csrf token, JSON request dispatch, and the 403-refresh-retry
//! policy. Replaces custom.js apiPost/ensureCsrfToken/withCsrf; the only csrf left in JS is
//! the minimal helper the multipart upload/export adapters use.
//!
//! Request state is MODULE-GLOBAL by design (S1 probe finding a): ziex's public fetch surface
//! is `zx.fetch` with a plain fn-pointer callback and no ctx parameter, so every in-flight
//! request lives in a fixed slot and the slot index rides in a comptime-generated callback.
//! Callers pass a u64 tag through untouched, which is how char_api tells a stale chat load
//! from the current one.

const std = @import("std");
const zx = @import("zx");
const char_store = @import("../cast/character_store.zig");
const server_events = @import("./server_events.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.net);

/// The C4 raw-bytes POST door op (patch-door D7). Unlike zx.fetch, which reads the request body with
/// readString (UTF-8) and returns the response via text(), this carries BOTH bodies as raw bytes, so
/// an uploaded image and a downloaded PNG survive the wasm boundary intact. Completion rides
/// __zx_fetch_complete through allocFetchId, so a raw POST reuses this module's slot + 403-retry.
extern "__zx" fn _fetchRawAsync(
    url_ptr: [*]const u8,
    url_len: usize,
    ctype_ptr: [*]const u8,
    ctype_len: usize,
    csrf_ptr: [*]const u8,
    csrf_len: usize,
    client_ptr: [*]const u8,
    client_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
    timeout_ms: u32,
    fetch_id: u64,
) void;

/// Completion callback. `res` is valid ONLY for the duration of the call; net.zig deinits
/// and destroys it right after (S1 probe finding b), so copy anything you keep.
pub const OnDone = *const fn (tag: u64, status: u16, res: ?*zx.Fetch.Response) void;

pub const Opts = struct {
    /// 403 = stale csrf token (server restarted under a long-lived tab): refresh + retry
    /// ONCE. NEVER set this for generation/relay endpoints: the server remaps upstream
    /// 401->403 and a blind retry double-submits a paid call. No such endpoint exists in
    /// the Zig layer yet; this flag is the seam the send loop must use when it lands.
    retry_403: bool = true,
    with_csrf: bool = true,
    method: zx.Fetch.Method = .POST,
};

const max_requests = 8;

const Slot = struct {
    active: bool = false,
    /// Waiting for the csrf token before dispatch.
    queued: bool = false,
    /// Raw-bytes POST (C4): dispatch via _fetchRawAsync, not zx.fetch, so binary bodies survive.
    raw: bool = false,
    url: []u8 = &.{},
    body: []u8 = &.{},
    /// The raw POST's request Content-Type (multipart with its boundary, or application/json); "" for
    /// the JSON zx.fetch path, which sets its own header.
    content_type: []u8 = &.{},
    opts: Opts = .{},
    retried: bool = false,
    tag: u64 = 0,
    on_done: OnDone = undefined,
};

var slots: [max_requests]Slot = @splat(.{});

var csrf_token: ?[]u8 = null;
var csrf_in_flight: bool = false;

/// Callbacks parked until the csrf token lands, for the streaming path (net.zig owns the token but
/// the SSE fetch runs in the door, not through a slot). Bounded; a full list drops the request.
var csrf_waiters: [max_requests]?*const fn () void = @splat(null);

/// The current csrf token, or null before the first /csrf-token fetch resolves. The streaming door op
/// reads it to set X-CSRF-Token; pair with ensureCsrfThen so a null token is fetched first.
pub fn currentCsrf() ?[]const u8 {
    return csrf_token;
}

/// Runs `cb` once a csrf token is available: immediately if one is cached, else after the shared
/// /csrf-token fetch resolves. The streaming orchestrator gates its door open on this so the POST
/// carries a token instead of eating a 403 on the first send after a server restart.
pub fn ensureCsrfThen(cb: *const fn () void) void {
    if (csrf_token != null) {
        cb();
        return;
    }
    for (&csrf_waiters) |*w| {
        if (w.* == null) {
            w.* = cb;
            ensureCsrf();
            return;
        }
    }
    log.err("csrf waiter list full, streaming open dropped", .{});
}

fn drainCsrfWaiters() void {
    for (&csrf_waiters) |*w| {
        if (w.*) |cb| {
            w.* = null;
            cb();
        }
    }
}

/// The slot index cannot ride on zx.fetch's plain callback, so each slot gets its own
/// comptime-stamped callback fn and the fn pointer IS the slot identity.
fn slotCb(comptime i: usize) zx.Fetch.ResponseCallback {
    return &struct {
        fn cb(res: ?*zx.Fetch.Response, err: ?zx.Fetch.FetchError) void {
            complete(i, res, err);
        }
    }.cb;
}

const slot_cbs: [max_requests]zx.Fetch.ResponseCallback = blk: {
    var arr: [max_requests]zx.Fetch.ResponseCallback = undefined;
    for (0..max_requests) |i| arr[i] = slotCb(i);
    break :blk arr;
};

/// JSON POST (or GET when opts.method says so) with csrf handling. `url` and `body` are
/// copied; the copies live until completion so a 403 retry can re-dispatch the same bytes.
pub fn request(url: []const u8, body: []const u8, tag: u64, on_done: OnDone, opts: Opts) void {
    const idx = freeSlot() orelse {
        log.err("request dropped, all {d} slots busy: {s}", .{ max_requests, url });
        on_done(tag, 0, null);
        return;
    };
    const url_c = alloc.dupe(u8, url) catch {
        on_done(tag, 0, null);
        return;
    };
    const body_c = alloc.dupe(u8, body) catch {
        alloc.free(url_c);
        on_done(tag, 0, null);
        return;
    };
    slots[idx] = .{
        .active = true,
        .url = url_c,
        .body = body_c,
        .opts = opts,
        .tag = tag,
        .on_done = on_done,
    };
    if (opts.with_csrf and csrf_token == null) {
        slots[idx].queued = true;
        ensureCsrf();
        return;
    }
    dispatch(idx);
}

/// A raw-bytes POST (C4): the multipart uploads and the binary character export. Same slot machinery,
/// csrf handling and 403-retry as request(); the difference is the door op, which carries the request
/// body and the response as raw bytes rather than UTF-8. `content_type` names the body (multipart with
/// its boundary, or application/json). `url`, `content_type` and `body` are copied until completion.
pub fn requestRaw(url: []const u8, content_type: []const u8, body: []const u8, tag: u64, on_done: OnDone, opts: Opts) void {
    const idx = freeSlot() orelse {
        log.err("raw request dropped, all {d} slots busy: {s}", .{ max_requests, url });
        on_done(tag, 0, null);
        return;
    };
    const url_c = alloc.dupe(u8, url) catch {
        on_done(tag, 0, null);
        return;
    };
    const body_c = alloc.dupe(u8, body) catch {
        alloc.free(url_c);
        on_done(tag, 0, null);
        return;
    };
    const ct_c = alloc.dupe(u8, content_type) catch {
        alloc.free(url_c);
        alloc.free(body_c);
        on_done(tag, 0, null);
        return;
    };
    slots[idx] = .{
        .active = true,
        .raw = true,
        .url = url_c,
        .body = body_c,
        .content_type = ct_c,
        .opts = opts,
        .tag = tag,
        .on_done = on_done,
    };
    if (opts.with_csrf and csrf_token == null) {
        slots[idx].queued = true;
        ensureCsrf();
        return;
    }
    dispatch(idx);
}

fn freeSlot() ?usize {
    for (&slots, 0..) |*s, i| {
        if (!s.active) return i;
    }
    return null;
}

fn dispatch(i: usize) void {
    const s = &slots[i];
    if (s.raw) {
        dispatchRaw(i);
        return;
    }
    log.debug("fetch {s}", .{s.url});
    // The door copies url/body/headers synchronously inside _fetchAsync (S1 probe finding e),
    // so the stack header array is safe.
    var headers: [3]zx.Fetch.RequestInit.Header = undefined;
    var n: usize = 0;
    if (s.opts.method == .POST) {
        headers[n] = .{ .name = "Content-Type", .value = "application/json" };
        n += 1;
    }
    if (s.opts.with_csrf) {
        if (csrf_token) |t| {
            headers[n] = .{ .name = "X-CSRF-Token", .value = t };
            n += 1;
        }
    }
    // The origin tag the live channel opened with. Without it on the write, the server has no way to
    // tell this tab's own change from another's and echoes it back, so the tab refetches itself.
    const origin = server_events.clientId();
    if (origin.len > 0) {
        headers[n] = .{ .name = "X-ST-Client-Id", .value = origin };
        n += 1;
    }
    _ = zx.fetch(zx.Io.wasm(slot_cbs[i]), alloc, s.url, .{
        .method = s.opts.method,
        .headers = headers[0..n],
        .body = if (s.opts.method == .POST) s.body else null,
    }) catch |err| {
        log.err("fetch dispatch failed: {s} {s}", .{ @errorName(err), s.url });
        finish(i, 0, null);
    };
}

fn dispatchRaw(i: usize) void {
    const s = &slots[i];
    log.debug("raw fetch {s}", .{s.url});
    const csrf: []const u8 = if (s.opts.with_csrf) (csrf_token orelse "") else "";
    const origin = server_events.clientId();
    // The slot IS the callback context; rawComplete recovers its index by pointer arithmetic, so the
    // door op's completion lands back on this same 403-retry path.
    const fid = zx.client.allocFetchId(alloc, @ptrCast(s), rawComplete) orelse {
        log.err("raw fetch dropped, no completion slot: {s}", .{s.url});
        finish(i, 0, null);
        return;
    };
    _fetchRawAsync(
        s.url.ptr,
        s.url.len,
        s.content_type.ptr,
        s.content_type.len,
        csrf.ptr,
        csrf.len,
        origin.ptr,
        origin.len,
        s.body.ptr,
        s.body.len,
        30_000,
        fid,
    );
}

fn rawComplete(ctx: *anyopaque, res: ?*zx.Fetch.Response, err: ?zx.Fetch.FetchError) void {
    const s: *Slot = @ptrCast(@alignCast(ctx));
    const i = (@intFromPtr(s) - @intFromPtr(&slots[0])) / @sizeOf(Slot);
    complete(i, res, err);
}

fn complete(i: usize, res: ?*zx.Fetch.Response, err: ?zx.Fetch.FetchError) void {
    const s = &slots[i];
    if (!s.active) {
        if (res) |r| destroyResponse(r);
        return;
    }
    if (err) |e| {
        log.err("fetch failed: {s} {s}", .{ @errorName(e), s.url });
        finish(i, 0, null);
        return;
    }
    const r = res orelse {
        finish(i, 0, null);
        return;
    };
    log.debug("{s} -> {d}", .{ s.url, r.status });
    if (r.status == 403 and s.opts.with_csrf and s.opts.retry_403 and !s.retried) {
        log.warn("{s} returned 403 - refreshing csrf token and retrying once", .{s.url});
        s.retried = true;
        s.queued = true;
        clearToken();
        destroyResponse(r);
        ensureCsrf();
        return;
    }
    finish(i, r.status, r);
}

fn finish(i: usize, status: u16, res: ?*zx.Fetch.Response) void {
    const s = &slots[i];
    const on_done = s.on_done;
    const tag = s.tag;
    const url = s.url;
    const body = s.body;
    const content_type = s.content_type;
    // Free the slot before the callback so on_done may issue a follow-up request into it.
    s.* = .{};
    on_done(tag, status, res);
    if (res) |r| destroyResponse(r);
    alloc.free(url);
    if (content_type.len > 0) alloc.free(content_type);
    // The body carries plaintext secrets (the connection panel POSTs the API key), and a freed wasm
    // allocation keeps its bytes until something reuses them, readable the whole time from JS via
    // the memory buffer. secureZero, not @memset: the store is dead to the optimiser otherwise.
    std.crypto.secureZero(u8, body);
    alloc.free(body);
}

/// LEAK TRAP (S1 probe finding b): the ziex client heap-creates the Response with the
/// allocator we pass to zx.fetch; res.deinit() frees body+headers only, so the struct
/// itself needs allocator.destroy or every fetch leaks one Response.
fn destroyResponse(r: *zx.Fetch.Response) void {
    r.deinit();
    alloc.destroy(r);
}

fn clearToken() void {
    if (csrf_token) |t| alloc.free(t);
    csrf_token = null;
}

fn ensureCsrf() void {
    if (csrf_token != null) {
        dispatchQueued();
        return;
    }
    if (csrf_in_flight) return;
    csrf_in_flight = true;
    // The token request itself never carries csrf and never retries.
    request("/csrf-token", "", 0, onCsrfDone, .{ .method = .GET, .with_csrf = false, .retry_403 = false });
}

fn onCsrfDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    csrf_in_flight = false;
    if (res != null and status >= 200 and status < 300) {
        if (res.?.json(struct { token: []const u8 = "" })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.token.len > 0) {
                clearToken();
                csrf_token = alloc.dupe(u8, parsed.value.token) catch null;
            } else {
                log.warn("csrf token response carried no token", .{});
            }
        } else |_| {
            log.warn("csrf token response unparseable", .{});
        }
    } else if (res != null) {
        log.warn("csrf token fetch returned {d}", .{status});
    } else {
        log.err("csrf token fetch failed: network error", .{});
    }
    // Queued requests go out either way; without a token a reachable server answers 403 and
    // the failure stays visible at the call site (matches the deleted glue).
    dispatchQueued();
    // Streaming waiters open their door fetch now (with the token if it arrived, else "" and the
    // reachable server answers 403 like any other request).
    drainCsrfWaiters();
}

fn dispatchQueued() void {
    for (&slots, 0..) |*s, i| {
        if (s.active and s.queued) {
            s.queued = false;
            dispatch(i);
        }
    }
}
