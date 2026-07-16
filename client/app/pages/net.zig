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
const char_store = @import("./character_store.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.net);

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
    url: []u8 = &.{},
    body: []u8 = &.{},
    opts: Opts = .{},
    retried: bool = false,
    tag: u64 = 0,
    on_done: OnDone = undefined,
};

var slots: [max_requests]Slot = @splat(.{});

var csrf_token: ?[]u8 = null;
var csrf_in_flight: bool = false;

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

fn freeSlot() ?usize {
    for (&slots, 0..) |*s, i| {
        if (!s.active) return i;
    }
    return null;
}

fn dispatch(i: usize) void {
    const s = &slots[i];
    log.debug("fetch {s}", .{s.url});
    // The door copies url/body/headers synchronously inside _fetchAsync (S1 probe finding e),
    // so the stack header array is safe.
    var headers: [2]zx.Fetch.RequestInit.Header = undefined;
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
    _ = zx.fetch(zx.Io.wasm(slot_cbs[i]), alloc, s.url, .{
        .method = s.opts.method,
        .headers = headers[0..n],
        .body = if (s.opts.method == .POST) s.body else null,
    }) catch |err| {
        log.err("fetch dispatch failed: {s} {s}", .{ @errorName(err), s.url });
        finish(i, 0, null);
    };
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
    // Free the slot before the callback so on_done may issue a follow-up request into it.
    s.* = .{};
    on_done(tag, status, res);
    if (res) |r| destroyResponse(r);
    alloc.free(url);
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
}

fn dispatchQueued() void {
    for (&slots, 0..) |*s, i| {
        if (s.active and s.queued) {
            s.queued = false;
            dispatch(i);
        }
    }
}
