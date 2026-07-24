//! The palette's browser-facing half: its own render region, the hotkey test, and the focus moves an
//! overlay owes the keyboard (WD39). The catalogue, the query and the highlight are pure and live in
//! palette_targets.zig; the markup and the activation, which is the only part needing ui.zig, live in
//! palette.zx.
//!
//! It carries its OWN region handle rather than one in shell/regions.zig for the same reason Toasts
//! has its own: a keystroke in the search box must re-render the palette and nothing else. Re-using
//! the Shell handle would rebuild both docks, the tabs and the gear on every letter typed.
//!
//! This module must NOT import ui.zig: ui.zig imports this one to open the palette from its
//! page-level key handler, and the pair would be a cycle. Anything needing ui.zig belongs in
//! palette.zx, which no .zig can import.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const targets = @import("./palette_targets.zig");
const dom_event = @import("../platform/dom_event.zig");

const log = std.log.scoped(.panels);

/// The search box's element id, shared by the markup, the focus move and the input read.
pub const input_id = "palette-input";

/// The palette's render handle, published by palette.zx on its first render.
pub var region: ?*zx.State(u32) = null;

/// Re-render the palette region alone. No-op before its first render.
pub fn bump() void {
    if (region) |h| h.set(h.get() +% 1);
}

/// Where focus goes when the palette closes without activating anything: whatever held it when the
/// palette opened. Held as a live element handle (the panel-drag precedent) because most of the
/// app's controls carry no id to look one up by.
var restore: ?js.Object = null;

pub fn isOpen() bool {
    return targets.isOpen();
}

/// Ctrl-K / Cmd-K, and nothing near it. Alt or Shift held means the user asked for a different
/// binding (Ctrl-Shift-K is the browser's own), so those fall through untouched.
///
/// It fires while the composer has focus ON PURPOSE: neither combination is a text-editing action
/// in a browser text control on Linux or Windows, and a palette you cannot reach mid-sentence is a
/// palette you stop using. The cost, stated rather than hidden: on macOS Ctrl-K is emacs
/// kill-to-end-of-line inside a text field, so a mac user gets the palette where they might have
/// killed a line. Cmd-K is the mac binding everything else uses, and it is bound here too.
pub fn isHotkey(ev: zx.client.Event, key: []const u8) bool {
    if (zx.platform.role != .client) return false;
    if (!std.mem.eql(u8, key, "k") and !std.mem.eql(u8, key, "K")) return false;
    if (!eventFlag(ev, "ctrlKey") and !eventFlag(ev, "metaKey")) return false;
    if (eventFlag(ev, "altKey")) return false;
    if (eventFlag(ev, "shiftKey")) return false;
    return true;
}

/// A boolean property off a raw keyboard event (ctrlKey, metaKey, altKey, shiftKey).
pub fn eventFlag(ev: zx.client.Event, comptime name: []const u8) bool {
    if (zx.platform.role != .client) return false;
    return ev.getEvent().ref.get(bool, name) catch false;
}

// ---- the document-level route (patch-door D12) --------------------------------------------------
// ziex delegates at <body> and walks UP from event.target, so a keydown with nothing focused (target
// IS <body>, which is where the browser leaves focus after a click on any non-focusable text) never
// reaches a handler. The delegated path above therefore covers the Shell and Composer subtrees only,
// and an accelerator that works in two thirds of the window is not an accelerator. The door reports
// every printable keydown here instead, crossing two numbers and no handle (the D11 discipline).
//
// The two routes cannot double-fire: the delegated one stops propagation on the key it takes, so the
// door's window listener never sees it, and `open` is idempotent besides.

const mod_ctrl: u32 = 1;
const mod_meta: u32 = 2;
const mod_alt: u32 = 4;
const mod_shift: u32 = 8;

/// One printable keydown from the door. Returns 1 when the palette took it, which is the door's
/// signal to preventDefault; Ctrl-K is the browser's own address-bar shortcut, so an unswallowed
/// one pulls focus clean out of the page.
///
/// The bit order is shared with the D12 block in patch-door.sh. Both name the same four bits in the
/// same order, and a change to one without the other silently mis-reads modifiers.
pub export fn __st_page_key(code: u32, mods: u32) callconv(.c) u32 {
    if (zx.platform.role != .client) return 0;
    if (code != 'k' and code != 'K') return 0;
    if (mods & (mod_alt | mod_shift) != 0) return 0;
    if (mods & (mod_ctrl | mod_meta) == 0) return 0;
    // Already up: swallow the key rather than toggling. A hotkey that closes what it just opened is
    // a hotkey people press twice by accident and lose their query to.
    if (targets.isOpen()) return 1;
    open();
    return 1;
}

/// Open the palette, remembering where focus was so Escape can hand it back, and put the caret in
/// the search box. The focus move waits a frame: the region render is scheduled, so the input does
/// not exist yet at the moment this returns.
pub fn open() void {
    if (targets.isOpen()) return;
    targets.open();
    // Capture before the sweep: making the background inert blurs whatever holds focus.
    captureFocus();
    setBackgroundInert(true);
    bump();
    if (zx.platform.role == .client) _ = zx.client.requestAnimationFrame(focusInputFrame);
    log.debug("palette open: {d} targets", .{targets.visibleCount()});
}

/// Escape or a click on the backdrop: close and hand focus back to whatever had it.
pub fn dismiss() void {
    if (!targets.isOpen()) return;
    targets.close();
    // Before the focus move, always: an inert element refuses focus silently, which would leave the
    // user on <body> with no way to tell where they are.
    setBackgroundInert(false);
    bump();
    restoreFocus();
}

/// Close after activating a target, moving focus to the control that owns the destination instead of
/// back to where the user came from. A jump is a change of place: leaving focus behind would strand
/// a keyboard user on a screen they no longer have.
pub fn closeOnto(id: []const u8) void {
    targets.close();
    setBackgroundInert(false);
    bump();
    dropRestore();
    focusById(id);
}

/// Make everything behind the palette genuinely unavailable while it is up. `aria-modal="true"` is
/// a PROMISE to assistive tech that the rest of the page is gone; a background that still takes Tab
/// turns that promise into a lie, and a screen-reader user lands in a page the app has told them
/// does not exist. `inert` is the attribute that keeps it: it drops the subtree from the focus order
/// AND from the accessibility tree in one move.
///
/// Swept over every #chat-root child except the palette, rather than a list of region ids: a region
/// added later is covered with no edit here. It cannot be applied to #chat-root itself, because
/// inert is inherited by the whole subtree and no descendant can opt back out, so the palette would
/// go inert with everything else.
///
/// COST, named rather than hidden: the toast overlay is a #chat-root child, so its aria-live
/// announcements are suppressed while the palette is open. That matches what aria-modal already
/// declares, and the palette is open for seconds at a time.
fn setBackgroundInert(on: bool) void {
    if (zx.platform.role != .client) return;
    const doc = js.global.get(js.Object, "document") catch return;
    defer doc.deinit();
    const root = (doc.call(?js.Object, "querySelector", .{js.string("#chat-root")}) catch null) orelse return;
    defer root.deinit();
    const kids = root.get(js.Object, "children") catch return;
    defer kids.deinit();
    const count = kids.get(f64, "length") catch return;
    if (count <= 0) return;
    var i: usize = 0;
    while (i < @as(usize, @intFromFloat(count))) : (i += 1) {
        const el = (kids.call(?js.Object, "item", .{@as(f64, @floatFromInt(i))}) catch null) orelse continue;
        defer el.deinit();
        const id = el.getAlloc(js.String, zx.allocator, "id") catch continue;
        defer zx.allocator.free(id);
        if (std.mem.eql(u8, id, "palette")) continue;
        if (on) {
            el.call(void, "setAttribute", .{ js.string("inert"), js.string("") }) catch {};
        } else {
            el.call(void, "removeAttribute", .{js.string("inert")}) catch {};
        }
    }
}

fn focusInputFrame() void {
    focusById(input_id);
}

/// Keep the highlighted row inside the list's own scroll window. The list caps at 46vh, so on a
/// short window the arrows walk the highlight past the fold, and a highlight nobody can see is the
/// same defect as no highlight at all. Rect deltas rather than offsetTop: the row's offsetParent is
/// the card, not the scrolling list, so offsets would be measured against the wrong box.
pub fn keepActiveVisible() void {
    if (zx.platform.role != .client) return;
    if (targets.visibleCount() == 0) return;
    var buf: [48]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "palette-opt-{d}", .{targets.activeIndex()}) catch return;
    const row = dom_event.elementById(zx.allocator, id) orelse return;
    defer row.deinit();
    const list = dom_event.elementById(zx.allocator, "palette-list") orelse return;
    defer list.deinit();
    const rr = row.ref.call(js.Object, "getBoundingClientRect", .{}) catch return;
    defer rr.deinit();
    const lr = list.ref.call(js.Object, "getBoundingClientRect", .{}) catch return;
    defer lr.deinit();
    const r_top = rr.get(f64, "top") catch return;
    const r_bottom = rr.get(f64, "bottom") catch return;
    const l_top = lr.get(f64, "top") catch return;
    const l_bottom = lr.get(f64, "bottom") catch return;
    const st = list.ref.get(f64, "scrollTop") catch return;
    if (r_top < l_top) {
        list.ref.set("scrollTop", st + (r_top - l_top)) catch {};
    } else if (r_bottom > l_bottom) {
        list.ref.set("scrollTop", st + (r_bottom - l_bottom)) catch {};
    }
}

fn focusById(id: []const u8) void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(zx.allocator, id) orelse {
        log.warn("palette could not focus #{s}: not in the document", .{id});
        return;
    };
    defer el.deinit();
    el.ref.call(void, "focus", .{}) catch {};
}

fn captureFocus() void {
    if (zx.platform.role != .client) return;
    dropRestore();
    const doc = js.global.get(js.Object, "document") catch return;
    defer doc.deinit();
    restore = doc.get(js.Object, "activeElement") catch null;
}

fn restoreFocus() void {
    if (zx.platform.role != .client) return;
    const el = restore orelse return;
    restore = null;
    defer el.deinit();
    // A control that left the document while the palette was up cannot take focus back; the browser
    // would drop it on <body> and the next Escape would reach nothing.
    if (!dom_event.isConnected(el)) return;
    el.call(void, "focus", .{}) catch {};
}

fn dropRestore() void {
    const el = restore orelse return;
    restore = null;
    el.deinit();
}

/// The search box's current text, owned by the caller. Read off the element rather than tracked in
/// the vtree: the input is uncontrolled (WD53), so the render never rewrites what is being typed.
pub fn readInputValue(ev: zx.client.Event) ?[]const u8 {
    if (zx.platform.role != .client) return null;
    const target = dom_event.plainTarget(ev) orelse return null;
    defer target.deinit();
    return target.getAlloc(js.String, zx.allocator, "value") catch null;
}
