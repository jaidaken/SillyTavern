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

const regions = @import("./regions.zig");

const log = std.log.scoped(.msg);

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

/// Snap the container to its full height across frames (glue owns the multi-frame settle: content-
/// visibility lays out late rows after the first frame, so a single snap lands short).
fn scrollBottom() void {
    js.global.call(void, "__st_reader_scroll_bottom", .{}) catch {};
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
    if (st < PREFETCH_MARGIN) js.global.call(void, "__st_reader_prefetch_schedule", .{}) catch {};
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

// ---- stream lifecycle (called from the JS pump) ------------------------------------------------

/// Stream opening: pin if the send forced it or you were already near the bottom, then clear the
/// one-shot force flag.
pub export fn __st_reader_stream_begin() callconv(.c) void {
    if (zx.platform.role != .client) return;
    stream_active = true;
    stream_pinned = send_forced_pin or nearBottomNow();
    send_forced_pin = false;
}

/// One stream flush: follow the bottom if pinned, else raise the chip (never while near the bottom).
pub export fn __st_reader_stream_tick() callconv(.c) void {
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
pub export fn __st_reader_stream_end() callconv(.c) void {
    if (zx.platform.role != .client) return;
    stream_active = false;
    if (stream_pinned) scrollBottom();
}

/// The near-bottom policy for the glue's 409 re-sync anchor: a near-bottom reader captures no anchor
/// and the re-sync tail-jumps instead. One source for the slop, read from JS.
pub export fn __st_reader_near_bottom() callconv(.c) i32 {
    if (zx.platform.role != .client) return 1;
    return if (nearBottomNow()) 1 else 0;
}
