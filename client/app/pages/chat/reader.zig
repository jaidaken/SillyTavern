//! The reverse-lazy reader's DECISION half: follow-the-bottom, the "New message" chip, and the
//! near-bottom policy all live here in Zig. The glue (`custom.js`) keeps only the IO primitives this
//! calls out to (the multi-frame rAF scroll-settle, the history fetch, the 409 re-sync DOM work).
//!
//! Scroll reaches this handler because patch-door D4 binds the delegated `scroll` event with capture,
//! so a scroll on the nested `#chat` scroller fires the body-delegated dispatch (scroll does not
//! bubble). `onscroll={reader.onScroll}` on `#chat` in messagelog.zx registers the handler.
//!
//! FOLLOW is two-way: a streamed reply pins to the bottom only while you are already near it; scroll
//! up and it unpins (the chip appears), scroll back near the bottom and it re-engages. NEAR is a
//! 120px slop (~5 lines) so "a few lines from the bottom" counts as the bottom. The chip is never
//! shown while near the bottom.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const regions = @import("../shell/regions.zig");
const pager = @import("./pager.zig");
const net = @import("../platform/net.zig");
const doorpack = @import("../platform/doorpack.zig");

const log = std.log.scoped(.msg);

/// Set by bootInit to char_api.reloadCurrentChat: the 409 re-sync trigger. A direct import would
/// cycle (char_api imports reader), so the prefetch reaches the re-sync through this pointer.
pub var resyncFn: ?*const fn () void = null;

// ~5 lines: a reply follows, and the chip stays hidden, anywhere within this of the bottom.
const BOTTOM_SLOP: f64 = 120;
// Scrolled within this of the top -> ask the glue to fetch the next older page.
const PREFETCH_MARGIN: f64 = 600;

// A stream follows the bottom only if `stream_pinned` (two-way, set off scroll position).
// `send_forced_pin` forces the NEXT stream to pin (the send scroll settles across frames).
var stream_active: bool = false;
var stream_pinned: bool = false;
var send_forced_pin: bool = false;
// The chip's visibility, mirrored into the MessageLog render via chipClass(). Toggled only on a
// threshold cross, and a change bumps the region so the chip re-renders when nothing else would.
var chip_visible: bool = false;

fn chatEl() ?js.Object {
    const doc = js.global.get(js.Object, "document") catch return null;
    defer doc.deinit();
    return doc.call(?js.Object, "querySelector", .{js.string("#chat")}) catch null;
}

fn nearBottomEl(chat: js.Object) bool {
    const st = chat.get(f64, "scrollTop") catch return true;
    const sh = chat.get(f64, "scrollHeight") catch return true;
    const ch = chat.get(f64, "clientHeight") catch return true;
    return (sh - st - ch) < BOTTOM_SLOP;
}

fn nearBottomNow() bool {
    const chat = chatEl() orelse return true;
    defer chat.deinit();
    return nearBottomEl(chat);
}

// The scroll-settle stops after 3 unchanged heights or 40 frames, matching the glue it replaced.
const SETTLE_STABLE_TARGET: u32 = 3;
const SETTLE_MAX_ITERS: u32 = 40;

// A single settle runs at a time; a re-entry restarts the counters. ziex binds no
// cancelAnimationFrame, so a pending guard stands in for cancel: at most one frame stays scheduled.
var settle_last_h: f64 = -1;
var settle_stable: u32 = 0;
var settle_iters: u32 = 0;
var settle_pending: bool = false;

/// Snap the container to its full height across frames: content-visibility lays out late rows after
/// the first frame, so a single snap lands short. Keeps snapping until the height stops growing.
pub fn scrollBottom() void {
    if (zx.platform.role != .client) return;
    settle_last_h = -1;
    settle_stable = 0;
    settle_iters = 0;
    if (settle_pending) return;
    settle_pending = true;
    _ = zx.client.requestAnimationFrame(settleFrame);
}

fn settleFrame() void {
    settle_pending = false;
    const chat = chatEl() orelse return;
    defer chat.deinit();
    const sh = chat.get(f64, "scrollHeight") catch return;
    chat.set("scrollTop", sh) catch {};
    if (sh == settle_last_h) {
        settle_stable += 1;
    } else {
        settle_stable = 0;
        settle_last_h = sh;
    }
    settle_iters += 1;
    if (settle_stable < SETTLE_STABLE_TARGET and settle_iters < SETTLE_MAX_ITERS) {
        settle_pending = true;
        _ = zx.client.requestAnimationFrame(settleFrame);
    }
}

// ---- 409 re-sync anchor (Zig-native; char_api calls captureAnchor/afterResync) ----------------

// The scrolled-up anchor a 409 re-sync must restore: its absolute chat index and its pixel offset
// from the scroller top. -1 = no anchor (reader was near the bottom, so the re-sync tail-jumps).
var resync_anchor_index: i64 = -1;
var resync_anchor_pixel: f64 = 0;

fn rectEdge(el: js.Object, edge: []const u8) ?f64 {
    const rect = el.call(js.Object, "getBoundingClientRect", .{}) catch return null;
    defer rect.deinit();
    return rect.get(f64, edge) catch null;
}

/// The first `.mes` whose bottom sits below the scroller's top edge (the on-screen anchor a prepend
/// must preserve), else the last `.mes`. Returns an owned handle the caller deinits.
fn anchorMes(chat: js.Object, chat_top: f64) ?js.Object {
    const list = chat.call(js.Object, "querySelectorAll", .{js.string(".mes")}) catch return null;
    defer list.deinit();
    const len = list.get(u32, "length") catch return null;
    if (len == 0) return null;
    var last_item: ?js.Object = null;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const item = list.call(js.Object, "item", .{i}) catch continue;
        const bottom = rectEdge(item, "bottom") orelse {
            item.deinit();
            continue;
        };
        if (bottom > chat_top + 1) {
            if (last_item) |li| li.deinit();
            return item;
        }
        if (last_item) |li| li.deinit();
        last_item = item;
    }
    return last_item;
}

fn absIndex(el: js.Object) ?i64 {
    const s = el.callAlloc(js.String, zx.allocator, "getAttribute", .{js.string("data-abs-index")}) catch return null;
    defer zx.allocator.free(s);
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch null;
}

/// Snapshot the on-screen anchor before a 409 re-sync reload rebuilds the window (char_api calls this
/// from reloadCurrentChat). A near-bottom reader captures nothing, so the re-sync tail-jumps.
pub fn captureAnchor() void {
    if (zx.platform.role != .client) return;
    resync_anchor_index = -1;
    if (nearBottomNow()) return;
    const chat = chatEl() orelse return;
    defer chat.deinit();
    const chat_top = rectEdge(chat, "top") orelse return;
    const anchor = anchorMes(chat, chat_top) orelse return;
    defer anchor.deinit();
    const idx = absIndex(anchor) orelse return;
    const a_top = rectEdge(anchor, "top") orelse return;
    resync_anchor_index = idx;
    resync_anchor_pixel = a_top - chat_top;
}

/// Set style.contentVisibility on `.chat-history .mes` (all of them, or the first `limit`).
fn setHistoryVisibility(chat: js.Object, value: []const u8, limit: ?u32) void {
    const hist = chat.call(js.Object, "querySelectorAll", .{js.string(".chat-history .mes")}) catch return;
    defer hist.deinit();
    const len = hist.get(u32, "length") catch return;
    const n = if (limit) |l| @min(l, len) else len;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const item = hist.call(js.Object, "item", .{i}) catch continue;
        defer item.deinit();
        const style = item.get(js.Object, "style") catch continue;
        defer style.deinit();
        style.set("contentVisibility", js.string(value)) catch {};
    }
}

/// Restore the reader after a 409 re-sync reload (char_api calls this from onChatDone). No anchor ->
/// tail-jump; else force history rows to real height (content-visibility estimates them) + scroll back.
pub fn afterResync() void {
    if (zx.platform.role != .client) return;
    if (resync_anchor_index < 0) {
        scrollBottom();
        return;
    }
    _ = zx.client.requestAnimationFrame(afterResyncFrame1);
}

fn afterResyncFrame1() void {
    _ = zx.client.requestAnimationFrame(afterResyncFrame2);
}

fn afterResyncFrame2() void {
    const target = resync_anchor_index;
    resync_anchor_index = -1;
    const chat = chatEl() orelse return;
    defer chat.deinit();
    setHistoryVisibility(chat, "visible", null);
    _ = chat.get(f64, "offsetHeight") catch {};
    var sel_buf: [64]u8 = undefined;
    const sel = std.fmt.bufPrint(&sel_buf, "[data-abs-index=\"{d}\"]", .{target}) catch {
        scrollBottom();
        setHistoryVisibility(chat, "", null);
        return;
    };
    const found = chat.call(?js.Object, "querySelector", .{js.string(sel)}) catch null;
    if (found) |el| {
        defer el.deinit();
        const chat_top = rectEdge(chat, "top") orelse 0;
        const el_top = rectEdge(el, "top") orelse chat_top;
        const cur = chat.get(f64, "scrollTop") catch 0;
        chat.set("scrollTop", cur + (el_top - chat_top) - resync_anchor_pixel) catch {};
    } else {
        scrollBottom();
    }
    setHistoryVisibility(chat, "", null);
}

// ---- older-page prefetch (Zig-native; the fetch rides net.zig, csrf + 403 handled there) --------

// The reader runs one prefetch at a time (`pumping`), so a fixed tag back from net.zig is enough.
const PREFETCH_TAG: u64 = 0;

var pumping: bool = false;
var scheduled: bool = false;

// The anchor a prepend must hold: the on-screen ref element (kept alive across the double rAF) and
// its top before the apply. `pref_before_count` sizes the content-visibility force to the added rows.
var pref_ref: ?js.Object = null;
var pref_ref_before: f64 = 0;
var pref_before_count: u32 = 0;

fn mesCount(chat: js.Object) u32 {
    const list = chat.call(js.Object, "querySelectorAll", .{js.string(".mes")}) catch return 0;
    defer list.deinit();
    return list.get(u32, "length") catch 0;
}

/// data-reader-state on #chat-root drives the marker row (loading spinner / error). null clears it.
fn setReaderState(state: ?[]const u8) void {
    const doc = js.global.get(js.Object, "document") catch return;
    defer doc.deinit();
    const root = (doc.call(?js.Object, "querySelector", .{js.string("#chat-root")}) catch null) orelse return;
    defer root.deinit();
    if (state) |s| {
        root.call(void, "setAttribute", .{ js.string("data-reader-state"), js.string(s) }) catch {};
    } else {
        root.call(void, "removeAttribute", .{js.string("data-reader-state")}) catch {};
    }
}

fn clearPrefRef() void {
    if (pref_ref) |r| {
        r.deinit();
        pref_ref = null;
    }
}

/// Coalesce prefetch triggers to one per frame (the scroll handler fires many), then re-check the
/// scroll position before the fetch so a fast scroll past the margin does not over-fetch.
pub fn schedulePrefetch() void {
    if (zx.platform.role != .client) return;
    if (scheduled) return;
    scheduled = true;
    _ = zx.client.requestAnimationFrame(scheduleFrame);
}

fn scheduleFrame() void {
    scheduled = false;
    const chat = chatEl() orelse return;
    defer chat.deinit();
    const st = chat.get(f64, "scrollTop") catch return;
    if (st < PREFETCH_MARGIN) prefetch();
}

fn prefetch() void {
    if (pumping or !pager.canPrepend()) return;
    const body_packed = pager.nextBody();
    if (body_packed == 0) return;
    pumping = true;
    setReaderState("loading");
    const body = @as([*]const u8, @ptrFromInt(doorpack.unpackPtr(body_packed)))[0..doorpack.unpackLen(body_packed)];
    const url_packed = pager.pageUrl();
    const url = if (url_packed == 0)
        "/api/chats/get"
    else
        @as([*]const u8, @ptrFromInt(doorpack.unpackPtr(url_packed)))[0..doorpack.unpackLen(url_packed)];
    net.request(url, body, PREFETCH_TAG, onPrefetchDone, .{});
}

fn onPrefetchDone(_: u64, status: u16, res: ?*zx.Fetch.Response) void {
    if (status == 409) {
        log.warn("history page stale (409) - re-syncing to the tail", .{});
        pager.abort();
        setReaderState(null);
        pumping = false;
        // Mirror the old __st_reader_resync door export: mark the re-sync, then reload the tail.
        pager.beginResync();
        if (resyncFn) |f| f();
        return;
    }
    if (res == null or status < 200 or status >= 300) {
        log.warn("history page fetch failed: {d}", .{status});
        pager.abort();
        setReaderState("error");
        pumping = false;
        return;
    }
    const text = res.?.text() catch {
        log.err("history prefetch: body read failed", .{});
        pager.abort();
        setReaderState("error");
        pumping = false;
        return;
    };
    // Measure the anchor on the pre-prepend DOM, then apply and correct across the double rAF.
    capturePrefetchAnchor();
    _ = pager.applyPage(text);
    setReaderState(null);
    _ = zx.client.requestAnimationFrame(prefCorrectFrame1);
}

fn capturePrefetchAnchor() void {
    clearPrefRef();
    pref_before_count = 0;
    const chat = chatEl() orelse return;
    defer chat.deinit();
    pref_before_count = mesCount(chat);
    const chat_top = rectEdge(chat, "top") orelse return;
    const ref = anchorMes(chat, chat_top) orelse return;
    pref_ref = ref;
    pref_ref_before = rectEdge(ref, "top") orelse {
        clearPrefRef();
        return;
    };
}

fn prefCorrectFrame1() void {
    _ = zx.client.requestAnimationFrame(prefCorrectFrame2);
}

fn prefCorrectFrame2() void {
    const chat = chatEl() orelse {
        clearPrefRef();
        pumping = false;
        return;
    };
    defer chat.deinit();
    const after_count = mesCount(chat);
    const added: u32 = if (after_count > pref_before_count) after_count - pref_before_count else 0;
    // Force the prepended rows to real height while correcting (content-visibility sizes them at the
    // 5rem estimate otherwise, so the anchor measures wrong), then revert.
    setHistoryVisibility(chat, "visible", added);
    _ = chat.get(f64, "offsetHeight") catch {};
    if (pref_ref) |ref| {
        const contains = chat.call(bool, "contains", .{ref}) catch false;
        if (contains) {
            const now_top = rectEdge(ref, "top") orelse pref_ref_before;
            const cur = chat.get(f64, "scrollTop") catch 0;
            chat.set("scrollTop", cur + (now_top - pref_ref_before)) catch {};
        }
    }
    setHistoryVisibility(chat, "", added);
    clearPrefRef();
    pumping = false;
    const st = chat.get(f64, "scrollTop") catch 0;
    if (st < PREFETCH_MARGIN) schedulePrefetch();
}

/// Toggle chip visibility, re-rendering the MessageLog region only when it actually changed. During
/// a stream the region already re-renders per flush, so this bump matters for the scroll-to-bottom
/// hide when no stream is running.
fn setChip(v: bool) void {
    if (chip_visible == v) return;
    chip_visible = v;
    regions.bumpMessageLog();
}

/// The chip element's class, read by messagelog.zx each render. Present in the DOM always (so the CSS
/// fade runs); `is-visible` toggles the opacity/pointer-events.
pub fn chipClass() []const u8 {
    return if (chip_visible) "chat-newmsg-chip is-visible" else "chat-newmsg-chip";
}

// ---- handlers (ziex, client-only) ------------------------------------------------------------

/// `#chat`'s scroll handler. Triggers the older-page prefetch near the top, re-engages/releases the
/// stream pin off the current position (two-way), and hides the chip once you are back at the bottom.
pub fn onScroll(_: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const chat = chatEl() orelse return;
    defer chat.deinit();
    const st = chat.get(f64, "scrollTop") catch return;
    if (st < PREFETCH_MARGIN) schedulePrefetch();
    const near = nearBottomEl(chat);
    if (stream_active) stream_pinned = near;
    if (near) setChip(false);
}

/// The chip's click: jump to the bottom, pin the running stream, and hide the chip.
pub fn onChipClick(_: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    stream_pinned = true;
    setChip(false);
    scrollBottom();
}

// ---- send-path pin (called from Zig: char_api, group_send) ------------------------------------

/// Your own send: force the next stream to follow the bottom no matter where the send scroll settled,
/// and jump there now. `stream_begin` honours `send_forced_pin` when the reply stream opens.
pub fn pinBottom() void {
    if (zx.platform.role != .client) return;
    send_forced_pin = true;
    stream_pinned = true;
    scrollBottom();
}

// ---- stream lifecycle (called from stream_drive) -----------------------------------------------

/// Stream opening: pin if the send forced it or you were already near the bottom, then clear the
/// one-shot force flag.
pub fn streamBegin() void {
    if (zx.platform.role != .client) return;
    stream_active = true;
    stream_pinned = send_forced_pin or nearBottomNow();
    send_forced_pin = false;
}

/// One stream flush: follow the bottom if pinned, else raise the chip (never while near the bottom).
pub fn streamTick() void {
    if (zx.platform.role != .client) return;
    if (stream_pinned) {
        scrollBottom();
        return;
    }
    const chat = chatEl() orelse {
        setChip(true);
        return;
    };
    defer chat.deinit();
    setChip(!nearBottomEl(chat));
}

/// Stream sealed: stop tracking, and land at the bottom if it had been following.
pub fn streamEnd() void {
    if (zx.platform.role != .client) return;
    stream_active = false;
    if (stream_pinned) scrollBottom();
}
