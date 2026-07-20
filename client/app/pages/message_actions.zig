//! Message action dispatch (C-MSG): the click/key delegate bound at the MessageLog region root.
//!
//! Owns the per-message action menu (open/close via store.menu, the copy action), then chains to
//! undo.zig for the undo controls and the panel-dismiss delegate. Controls carry data-msg-* / data-*
//! attributes rather than their own onclick, so ziex's body-delegated dispatch resolves them here
//! (ZX11) off event.target. Copy is the only history-safe action wired this phase; edit/delete/move/
//! hide/swipe route to a stub until the server mutation routes land (the pure store ops already exist).
//!
//! zx-importing (DOM + clipboard), so browser-verified via the interactions gate (ZX5); the pure menu
//! state and the store mutation ops live in store.zig under `zig build test`.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const store = @import("./store.zig");
const message_editor = @import("./message_editor.zig");
const undo = @import("./undo.zig");
const regions = @import("./regions.zig");
const dom_event = @import("./dom_event.zig");
const net = @import("./net.zig");
const pager = @import("./pager.zig");
const char_api = @import("./char_api.zig");
const char_store = @import("./character_store.zig");

const alloc = store.page_gpa;
const log = std.log.scoped(.msg);
const net_log = std.log.scoped(.net);

/// The MessageLog region's click delegate: the action-menu trigger and its items first, then a click
/// outside an open menu dismisses it, then undo.onLogClick runs (its undo controls and panel dismiss).
pub fn onLogClick(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse {
        undo.onLogClick(ev);
        return;
    };

    // w3-reason: the reasoning-block header toggles its collapsed state.
    if (dom_event.datasetUp(target, "reasonToggle")) |idx_str| {
        defer zx.allocator.free(idx_str);
        const abs = std.fmt.parseInt(usize, idx_str, 10) catch return;
        store.reasoning.toggle(abs);
        regions.bumpMessageLog();
        return;
    }

    // The trigger toggles the popped action list, anchored under it.
    if (dom_event.datasetUp(target, "msgMenu")) |idx_str| {
        defer zx.allocator.free(idx_str);
        const abs = std.fmt.parseInt(usize, idx_str, 10) catch return;
        captureAnchor(target);
        store.menu.toggle(abs);
        regions.bumpMessageLog();
        return;
    }

    // A menu action; data-msg-index carries the message's absolute index.
    if (dom_event.datasetUp(target, "msgAction")) |action| {
        defer zx.allocator.free(action);
        const abs = blk: {
            const idx_str = dom_event.datasetUp(target, "msgIndex") orelse break :blk null;
            defer zx.allocator.free(idx_str);
            break :blk std.fmt.parseInt(usize, idx_str, 10) catch null;
        };
        dispatch(action, abs);
        return;
    }

    // "Earlier versions" reuses undo's own history path (it captures the anchor and opens the version
    // popover); drop our menu first so the two overlays never stack, then fall through to undo.
    if (dom_event.datasetUp(target, "undoHistory")) |flag| {
        zx.allocator.free(flag);
        store.menu.close();
        undo.onLogClick(ev);
        return;
    }

    if (store.menu.open_index != null and !dom_event.hasAncestorId(target, "msg-menu")) {
        store.menu.close();
        regions.bumpMessageLog();
    }
    undo.onLogClick(ev);
}

/// The region's keydown delegate: Escape closes an open action menu first, then undo.onLogKey runs.
pub fn onLogKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;

    // While the inline editor is open its keys win: Escape cancels, Ctrl/Cmd+Enter saves, and every
    // other key is left to the contenteditable (plain Enter inserts a newline).
    if (message_editor.currentAbs()) |abs| {
        const key = ev.key() orelse return;
        defer zx.allocator.free(key);
        if (std.mem.eql(u8, key, "Escape")) {
            ev.preventDefault();
            cancelEdit();
        } else if (std.mem.eql(u8, key, "Enter")) {
            const ctrl = ev.getEvent().ref.get(bool, "ctrlKey") catch false;
            const meta = ev.getEvent().ref.get(bool, "metaKey") catch false;
            if (ctrl or meta) {
                ev.preventDefault();
                saveEdit(abs);
            }
        }
        return;
    }

    if (store.menu.open_index != null) {
        const key = ev.key() orelse {
            undo.onLogKey(ev);
            return;
        };
        defer zx.allocator.free(key);
        if (std.mem.eql(u8, key, "Escape")) {
            store.menu.close();
            regions.bumpMessageLog();
            return;
        }
    }
    undo.onLogKey(ev);
}

fn dispatch(action: []const u8, abs: ?usize) void {
    if (std.mem.eql(u8, action, "copy")) {
        copyMessage(abs);
    } else if (abs) |a| {
        // edit/save/cancel drive their own render (the in-place editor), so they skip the trailing bump.
        if (std.mem.eql(u8, action, "edit")) {
            editMessage(a);
            return;
        } else if (std.mem.eql(u8, action, "save-edit")) {
            saveEdit(a);
            return;
        } else if (std.mem.eql(u8, action, "cancel-edit")) {
            cancelEdit();
            return;
        } else if (std.mem.eql(u8, action, "delete")) {
            deleteMessage(a);
        } else if (std.mem.eql(u8, action, "hide")) {
            hideMessage(a);
        } else if (std.mem.eql(u8, action, "moveup")) {
            moveMessage(a, "up");
        } else if (std.mem.eql(u8, action, "movedown")) {
            moveMessage(a, "down");
        } else {
            log.warn("unknown message action '{s}'", .{action});
        }
    }
    store.menu.close();
    regions.bumpMessageLog();
}

const Ident = struct { avatar: []const u8, file: []const u8 };

/// The open chat's identity for a mutation, or null when nothing with a saved file is selected.
fn ident() ?Ident {
    const c = char_store.selected() orelse return null;
    if (c.avatar.len == 0 or c.chat.len == 0) return null;
    return .{ .avatar = c.avatar, .file = c.chat };
}

/// The raw source body of the message at absolute index `abs`, or null when it is outside the window.
fn bodyAt(abs: usize) ?[]const u8 {
    const wo = store.windowOffset();
    if (abs < wo) return null;
    const i = abs - wo;
    const msgs = store.slice();
    if (i >= msgs.len) return null;
    return msgs[i].body;
}

/// Dispatch a built mutation body to `route` and re-sync on completion. `body` is owned by the caller.
/// The mutation always carries the ABSOLUTE file index so a windowed reader edits the right message,
/// never one above the window (the T0 dangerous property), and the whole-file token, never the tail
/// token which 409s by design.
fn post(route: []const u8, body: []const u8) void {
    net.request(route, body, 0, onMutateDone, .{});
}

/// Open the inline live-markdown editor over message `abs`. message_editor turns the body node into a
/// contenteditable in place (no vdom swap); the bump closes the action menu first. Its save/cancel
/// buttons carry data-msg-action, so they dispatch straight back through onLogClick.
fn editMessage(abs: usize) void {
    if (zx.platform.role != .client) return;
    const raw = bodyAt(abs) orelse return;
    const raw_copy = alloc.dupe(u8, raw) catch return;
    defer alloc.free(raw_copy);
    store.menu.close();
    regions.bumpMessageLog();
    message_editor.open(abs, raw_copy);
}

/// Close the editor without writing; message_editor restores the rendered body it captured on open.
fn cancelEdit() void {
    if (zx.platform.role != .client) return;
    message_editor.cancel();
}

/// Persist the editor's raw text via the edit route. An empty result cancels rather than blanking the
/// message. onMutateDone re-syncs, which rebuilds the node fresh, so the editor node is dropped there.
fn saveEdit(abs: usize) void {
    if (zx.platform.role != .client) return;
    const id = ident() orelse return cancelEdit();
    const text = message_editor.readText() orelse return cancelEdit();
    defer alloc.free(text);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return cancelEdit();
    message_editor.close();
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = id.avatar,
        .file_name = id.file,
        .index = abs,
        .mes = text,
        .change_token = pager.fullToken(),
    }, .{}) catch return;
    defer alloc.free(body);
    post("/api/chats/message/edit", body);
}

fn deleteMessage(abs: usize) void {
    if (zx.platform.role != .client) return;
    const id = ident() orelse return;
    if (!confirmDialog("Delete this message? This cannot be undone.")) return;
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = id.avatar,
        .file_name = id.file,
        .index = abs,
        .change_token = pager.fullToken(),
    }, .{}) catch return;
    defer alloc.free(body);
    post("/api/chats/message/delete", body);
}

fn hideMessage(abs: usize) void {
    if (zx.platform.role != .client) return;
    const id = ident() orelse return;
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = id.avatar,
        .file_name = id.file,
        .index = abs,
        .change_token = pager.fullToken(),
    }, .{}) catch return;
    defer alloc.free(body);
    post("/api/chats/message/hide", body);
}

fn moveMessage(abs: usize, direction: []const u8) void {
    if (zx.platform.role != .client) return;
    const id = ident() orelse return;
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = id.avatar,
        .file_name = id.file,
        .index = abs,
        .direction = direction,
        .change_token = pager.fullToken(),
    }, .{}) catch return;
    defer alloc.free(body);
    post("/api/chats/message/move", body);
}

/// Shared mutation completion: a 409 (or success) both re-sync the reader to the fresh tail through the
/// existing path (pager.beginResync + char_api.reloadCurrentChat), so the store is rebuilt server-side
/// and above-window history is never touched by the client. Adopt the returned tokens first.
fn onMutateDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (status == 409) {
        net_log.info("message mutation: file changed (409), re-syncing to the tail", .{});
        pager.beginResync();
        char_api.reloadCurrentChat();
        return;
    }
    if (status < 200 or status >= 300) {
        net_log.warn("message mutation failed: {d} - chat unchanged", .{status});
        return;
    }
    if (res) |r| {
        if (r.json(struct { change_token: []const u8 = "", tail_token: []const u8 = "" })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.change_token.len > 0) pager.setFullToken(parsed.value.change_token);
            if (parsed.value.tail_token.len > 0) pager.adoptToken(parsed.value.tail_token);
        } else |_| {}
    }
    pager.beginResync();
    char_api.reloadCurrentChat();
}

fn confirmDialog(msg: []const u8) bool {
    if (zx.platform.role != .client) return false;
    return js.global.call(bool, "confirm", .{js.string(msg)}) catch false;
}

/// Copy the raw source text of the message at absolute index `abs` to the clipboard. No endpoint and
/// no history write: it reads the store's own body (the markdown source, not the rendered HTML).
fn copyMessage(abs: ?usize) void {
    if (zx.platform.role != .client) return;
    const a = abs orelse return;
    const wo = store.windowOffset();
    if (a < wo) return;
    const i = a - wo;
    const msgs = store.slice();
    if (i >= msgs.len) return;
    writeClipboard(msgs[i].body);
}

fn writeClipboard(text: []const u8) void {
    if (zx.platform.role != .client) return;
    const nav = js.global.get(js.Object, "navigator") catch return;
    defer nav.deinit();
    const clip = nav.get(js.Object, "clipboard") catch {
        log.warn("clipboard API unavailable", .{});
        return;
    };
    defer clip.deinit();
    // writeText returns a Promise handle we own; nothing awaits it, so free it and let a rejection
    // leave the clipboard unchanged.
    const promise = clip.call(js.Object, "writeText", .{js.string(text)}) catch {
        log.warn("clipboard write failed", .{});
        return;
    };
    promise.deinit();
}

/// Record where the popped list should sit: under the trigger, right-aligned to it. Read from the
/// trigger's viewport rect because the list renders fixed at the MessageLog root (a `.mes`-local
/// absolute popover is clipped by the message's paint containment).
/// The action list runs ~240px tall (7 items); used to decide whether it fits below the trigger.
const MENU_EST_PX: f64 = 240;

fn captureAnchor(el: js.Object) void {
    if (zx.platform.role != .client) return;
    const rect = el.call(js.Object, "getBoundingClientRect", .{}) catch return;
    defer rect.deinit();
    const top = rect.get(f64, "top") catch return;
    const bottom = rect.get(f64, "bottom") catch return;
    const right = rect.get(f64, "right") catch return;
    const inner_w = js.global.get(f64, "innerWidth") catch return;
    const inner_h = js.global.get(f64, "innerHeight") catch return;
    const right_gap: f32 = @floatCast(inner_w - right);
    // Open upward (anchor the list's bottom above the trigger) when it would run off the viewport
    // bottom and there is more room above, so a message near the bottom keeps Delete reachable.
    const space_below = inner_h - bottom;
    if (space_below < MENU_EST_PX and top > space_below) {
        store.menu.setAnchor(@floatCast(inner_h - top + 4), right_gap, true);
    } else {
        store.menu.setAnchor(@floatCast(bottom + 4), right_gap, false);
    }
}

/// Inline `position: fixed` placement for the popped action list, from the captured anchor. `up`
/// anchors the list's bottom above the trigger; a viewport-bounded max-height keeps it fully scrollable.
pub fn anchorStyle(allocator: std.mem.Allocator, offset: f32, right: f32, up: bool) []const u8 {
    const edge: []const u8 = if (up) "bottom" else "top";
    return std.fmt.allocPrint(allocator, "position:fixed;{s}:{d}px;right:{d}px;max-height:calc(100dvh - 16px);overflow-y:auto", .{
        edge, @as(i32, @intFromFloat(offset)), @as(i32, @intFromFloat(right)),
    }) catch "position:fixed;top:64px;right:16px;max-height:calc(100dvh - 16px);overflow-y:auto";
}
