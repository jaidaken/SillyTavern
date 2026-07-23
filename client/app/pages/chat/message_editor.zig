//! The inline message editor's DOM half: turn a rendered message body into a live-markdown
//! `contenteditable` in place, re-colour it on every keystroke, keep the caret, and read the raw
//! text back on save. The pure highlighter is `md_highlight.zig` (zx-free, unit-tested); this file
//! is the browser-verified DOM glue (ZX5).
//!
//! WHY IN PLACE, NOT A VDOM SWAP: the framework only rewrites a message node when its model text
//! changed, so an untouched body is left alone across whole-page re-renders. We overwrite that one
//! node's `innerHTML` imperatively (the same `js.set` the codebase uses in appearance/connection/
//! card_editor) and the framework never fights us for it: no structural child swap (which trips the
//! vdom's positional diff, the `_rpc replace dropped` anomaly), no re-sanitise pass (which would
//! strip the editor's buttons). Save reloads the chat, which rebuilds the node fresh.
//!
//! CARET DOMAIN: the DOM measures text offsets in UTF-16 code units; the highlighter works in bytes.
//! The two never mix here: every offset is read straight off DOM Text nodes (`.length`) and Range
//! endpoints, so a non-ASCII character never desynchronises the caret.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const md = @import("../platform/md_highlight.zig");
const store = @import("../platform/store.zig");
const dom_event = @import("../platform/dom_event.zig");

const alloc = store.page_gpa;
const log = std.log.scoped(.msg);

// NodeFilter.SHOW_TEXT: the whatToShow mask that makes a TreeWalker visit only text nodes.
const SHOW_TEXT: i32 = 4;

// One editor is open at a time. `saved_html` is the rendered body captured on open, restored on
// cancel; `editing_abs` is the message it belongs to.
var editing_abs: ?usize = null;
var saved_html: ?[]u8 = null;

/// The message an editor is currently open over, or null when none is. Read by the region's key
/// handler so Escape/Ctrl+Enter route to the editor while it is open.
pub fn currentAbs() ?usize {
    return editing_abs;
}

fn document() ?js.Object {
    return js.global.get(js.Object, "document") catch null;
}

/// `document.querySelector(sel)`, or null. Caller deinits the result.
fn query(sel: []const u8) ?js.Object {
    const doc = document() orelse return null;
    defer doc.deinit();
    return doc.call(?js.Object, "querySelector", .{js.string(sel)}) catch null;
}

/// Open the editor over message `abs`, seeded with its raw source `raw`. Replaces the body node's
/// contents with a contenteditable field (highlighted) plus the save/cancel buttons, then focuses
/// the field and drops the caret at the end.
pub fn open(abs: usize, raw: []const u8) void {
    if (zx.platform.role != .client) return;

    const body_sel = std.fmt.allocPrint(alloc, ".mes[data-abs-index=\"{d}\"] .mes_text", .{abs}) catch return;
    defer alloc.free(body_sel);
    const node = query(body_sel) orelse {
        log.warn("edit: message body {d} not found", .{abs});
        return;
    };
    defer node.deinit();

    const hl = md.highlight(alloc, raw) catch return;
    defer alloc.free(hl);

    // The field keeps mes_text so the source sits at the message's own measure and family. The
    // buttons carry data-msg-action so the region's existing click delegate dispatches them.
    const editor = std.fmt.allocPrint(
        alloc,
        "<div class=\"mes_edit\">" ++
            "<div class=\"mes_edit_field mes_text\" contenteditable=\"true\" role=\"textbox\" aria-multiline=\"true\" aria-label=\"Edit message\" data-edit-field=\"{d}\">{s}</div>" ++
            "<div class=\"mes_edit_actions\">" ++
            "<button type=\"button\" class=\"mes_edit_save\" data-msg-action=\"save-edit\" data-msg-index=\"{d}\" aria-label=\"Save\">\u{2713}</button>" ++
            "<button type=\"button\" class=\"mes_edit_cancel\" data-msg-action=\"cancel-edit\" data-msg-index=\"{d}\" aria-label=\"Cancel\">\u{2715}</button>" ++
            "</div></div>",
        .{ abs, hl, abs, abs },
    ) catch return;
    defer alloc.free(editor);

    const prev = node.getAlloc(js.String, alloc, "innerHTML") catch return;

    // allow-raw-html-sink: this markup is generated here; its only dynamic part (hl) is the message's
    // own body run through md_highlight, which HTML-escapes every text byte and adds no untrusted input.
    node.set("innerHTML", js.string(editor)) catch {
        alloc.free(prev);
        return;
    };

    if (saved_html) |old| alloc.free(old);
    saved_html = prev;
    editing_abs = abs;

    const field = node.call(?js.Object, "querySelector", .{js.string(".mes_edit_field")}) catch null;
    if (field) |f| {
        defer f.deinit();
        f.call(void, "focus", .{}) catch {};
        caretToEnd(f);
    }
}

/// The region's `oninput` delegate: when the event is the edit field, re-highlight it. A no-op for
/// any other input in the message log.
pub fn onInput(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return;
    const marker = dom_event.datasetUp(target, "editField") orelse return;
    zx.allocator.free(marker);
    // Mid-IME-composition input carries partial glyphs; re-colouring then corrupts them. The final
    // input event of a composition has isComposing=false and re-highlights the settled text.
    const composing = ev.getEvent().ref.get(bool, "isComposing") catch false;
    if (composing) return;
    rehighlight(target);
}

/// Re-wrap the field from its current text, preserving the caret. `field` is event.target.
fn rehighlight(field: js.Object) void {
    const raw = field.getAlloc(js.String, alloc, "textContent") catch return;
    defer alloc.free(raw);
    const off = caretOffset(field);
    const hl = md.highlight(alloc, raw) catch return;
    defer alloc.free(hl);
    // allow-raw-html-sink: hl is md_highlight over the field's own textContent, every byte escaped.
    field.set("innerHTML", js.string(hl)) catch return;
    if (off >= 0) setCaret(field, off);
}

/// The editor's current raw markdown (the field's textContent). Caller owns the returned bytes.
pub fn readText() ?[]u8 {
    if (zx.platform.role != .client) return null;
    const field = query(".mes_edit_field") orelse return null;
    defer field.deinit();
    return field.getAlloc(js.String, alloc, "textContent") catch null;
}

/// Close the editor without writing, restoring the rendered body captured on open.
pub fn cancel() void {
    if (zx.platform.role != .client) return;
    restoreBody();
    clear();
}

/// Drop editor state after a successful save. The mutation reload rebuilds the node with the new
/// body, so there is nothing to restore.
pub fn close() void {
    if (zx.platform.role != .client) return;
    clear();
}

fn restoreBody() void {
    const abs = editing_abs orelse return;
    const html = saved_html orelse return;
    const sel = std.fmt.allocPrint(alloc, ".mes[data-abs-index=\"{d}\"] .mes_text", .{abs}) catch return;
    defer alloc.free(sel);
    const node = query(sel) orelse return;
    defer node.deinit();
    // allow-raw-html-sink: html is this node's own prior innerHTML, captured in open().
    node.set("innerHTML", js.string(html)) catch {};
}

fn clear() void {
    if (saved_html) |h| {
        alloc.free(h);
        saved_html = null;
    }
    editing_abs = null;
}

// ---- caret (UTF-16 domain, straight off the DOM) ---------------------------------------------

fn applyRange(range: js.Object) void {
    const sel = js.global.call(js.Object, "getSelection", .{}) catch return;
    defer sel.deinit();
    sel.call(void, "removeAllRanges", .{}) catch {};
    sel.call(void, "addRange", .{range}) catch {};
}

fn caretToEnd(field: js.Object) void {
    const doc = document() orelse return;
    defer doc.deinit();
    const range = doc.call(js.Object, "createRange", .{}) catch return;
    defer range.deinit();
    range.call(void, "selectNodeContents", .{field}) catch return;
    range.call(void, "collapse", .{false}) catch return;
    applyRange(range);
}

/// The caret's offset in UTF-16 units from the field start, or -1 if there is no selection. Walks
/// the field's text nodes, summing their lengths until the one the caret sits in.
fn caretOffset(field: js.Object) i32 {
    const sel = js.global.call(js.Object, "getSelection", .{}) catch return -1;
    defer sel.deinit();
    const rc = sel.get(i32, "rangeCount") catch return -1;
    if (rc == 0) return -1;
    const r = sel.call(js.Object, "getRangeAt", .{@as(i32, 0)}) catch return -1;
    defer r.deinit();
    const endc = r.get(js.Object, "endContainer") catch return -1;
    defer endc.deinit();
    const endo = r.get(i32, "endOffset") catch return -1;

    const doc = document() orelse return -1;
    defer doc.deinit();
    const walker = doc.call(js.Object, "createTreeWalker", .{ field, SHOW_TEXT }) catch return -1;
    defer walker.deinit();

    var acc: i32 = 0;
    while (true) {
        const node = walker.call(?js.Object, "nextNode", .{}) catch break;
        const n = node orelse break;
        defer n.deinit();
        const same = n.call(bool, "isSameNode", .{endc}) catch false;
        if (same) return acc + endo;
        acc += n.get(i32, "length") catch 0;
    }
    return acc;
}

/// Place the caret at UTF-16 `offset` from the field start, walking its text nodes to find the node
/// that offset lands in. Past the end, collapse to the end of the field.
fn setCaret(field: js.Object, offset: i32) void {
    const doc = document() orelse return;
    defer doc.deinit();
    const walker = doc.call(js.Object, "createTreeWalker", .{ field, SHOW_TEXT }) catch return;
    defer walker.deinit();

    var acc: i32 = 0;
    while (true) {
        const node = walker.call(?js.Object, "nextNode", .{}) catch break;
        const n = node orelse break;
        defer n.deinit();
        const nlen = n.get(i32, "length") catch 0;
        if (offset <= acc + nlen) {
            const range = doc.call(js.Object, "createRange", .{}) catch return;
            defer range.deinit();
            range.call(void, "setStart", .{ n, offset - acc }) catch return;
            range.call(void, "collapse", .{true}) catch return;
            applyRange(range);
            return;
        }
        acc += nlen;
    }
    caretToEnd(field);
}
