//! Undo UI orchestration (C4): drives the two undo surfaces off the deployed backup endpoints.
//!
//! The per-message version popover and the whole-chat snapshot overlay both read `store.undo`; this
//! module fetches into it and handles the clicks. A restore MUTATES the chat file, so on success the
//! reader is re-synced through its existing 409 path (`pager.beginResync` + `char_api.reloadCurrentChat`),
//! never by writing the store window directly. The undo `change_token` from a versions/snapshots
//! response is threaded into the matching restore; it is NOT the reader spine token (`pager.currentToken`).
//!
//! zx-importing (fetch + DOM handlers), so browser-verified via `client/verify.sh`; the pure state and
//! its lifetimes live in `store.zig` under `zig build test` (ZX5).

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const net = @import("./net.zig");
const store = @import("./store.zig");
const char_store = @import("./character_store.zig");
const pager = @import("./pager.zig");
const char_api = @import("./char_api.zig");
const regions = @import("./regions.zig");
const dom_event = @import("./dom_event.zig");
const ui = @import("./ui.zig");

const alloc = store.page_gpa;
const log = std.log.scoped(.undo);

// ---- response shapes (Response.json ignores unknown fields) --------------------------------

const VersionJson = struct {
    mes: []const u8 = "",
    backup_ts: []const u8 = "",
    matched: bool = false,
};
const VersionsResp = struct {
    versions: []const VersionJson = &.{},
    change_token: []const u8 = "",
};
const SnapshotJson = struct {
    backup_ts: []const u8 = "",
    message_count: usize = 0,
    last_mes_preview: []const u8 = "",
    added: usize = 0,
    removed: usize = 0,
    edited: usize = 0,
    too_large: bool = false,
};
const SnapshotsResp = struct {
    snapshots: []const SnapshotJson = &.{},
    change_token: []const u8 = "",
};

// ---- identity ------------------------------------------------------------------------------

const Ident = struct { avatar: []const u8, file: []const u8 };

/// The open chat's solo identity for an undo request, or null when nothing with a saved file is open
/// (a fresh unsaved chat, demo mode, or a group: undo is solo-only this phase).
fn currentIdent() ?Ident {
    const c = char_store.selected() orelse return null;
    if (c.avatar.len == 0 or c.chat.len == 0) return null;
    return .{ .avatar = c.avatar, .file = c.chat };
}

// ---- version history (per message) ---------------------------------------------------------

/// Open the version popover for the message at absolute index `abs` and fetch its history. Toggles
/// shut if that message's popover is already open.
pub fn openVersionsFor(abs: usize) void {
    if (zx.platform.role != .client) return;
    if (store.undo.isVersionsOpenFor(abs)) {
        store.undo.close();
        regions.bumpMessageLog();
        return;
    }
    store.undo.openVersions(abs);
    regions.bumpMessageLog();
    focusSurface();

    const id = currentIdent() orelse {
        store.undo.setBusy(false);
        store.undo.setNote("No saved history for this chat.");
        regions.bumpMessageLog();
        return;
    };
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = id.avatar,
        .file_name = id.file,
        .index = abs,
    }, .{}) catch {
        store.undo.setBusy(false);
        store.undo.setNote("Could not load history.");
        regions.bumpMessageLog();
        return;
    };
    defer alloc.free(body);
    net.request("/api/chats/backups/message-versions", body, abs, onVersionsDone, .{});
}

fn onVersionsDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    // A different message's popover (or a close) took over while this was in flight: drop it.
    if (store.undo.mode != .versions or store.undo.target_index != tag) return;
    store.undo.setBusy(false);
    if (res == null or status < 200 or status >= 300) {
        store.undo.setNote("Could not load history.");
        regions.bumpMessageLog();
        return;
    }
    const parsed = res.?.json(VersionsResp) catch {
        store.undo.setNote("Could not read history.");
        regions.bumpMessageLog();
        return;
    };
    defer parsed.deinit();
    store.undo.setToken(parsed.value.change_token);
    for (parsed.value.versions) |v| store.undo.addVersion(v.mes, v.backup_ts, v.matched);
    if (store.undo.versions.items.len == 0) store.undo.setNote("No earlier versions of this message.");
    regions.bumpMessageLog();
}

fn restoreVersion(backup_ts: []const u8) void {
    if (store.undo.mode != .versions) return;
    const id = currentIdent() orelse return;
    const abs = store.undo.target_index;
    store.undo.setBusy(true);
    regions.bumpMessageLog();
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = id.avatar,
        .file_name = id.file,
        .index = abs,
        .backup_ts = backup_ts,
        .change_token = store.undo.change_token,
    }, .{}) catch return failRestore();
    defer alloc.free(body);
    net.request("/api/chats/backups/restore-message", body, 0, onRestoreDone, .{});
}

// ---- whole-chat snapshots ------------------------------------------------------------------

/// Open (or toggle shut) the whole-chat snapshot overlay and fetch the save points.
pub fn onOpenSnapshots(_: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    if (store.undo.mode == .snapshots) {
        store.undo.close();
        regions.bumpMessageLog();
        return;
    }
    store.undo.openSnapshots();
    regions.bumpMessageLog();
    focusSurface();

    const id = currentIdent() orelse {
        store.undo.setBusy(false);
        store.undo.setNote("No saved snapshots for this chat.");
        regions.bumpMessageLog();
        return;
    };
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = id.avatar,
        .file_name = id.file,
    }, .{}) catch {
        store.undo.setBusy(false);
        store.undo.setNote("Could not load snapshots.");
        regions.bumpMessageLog();
        return;
    };
    defer alloc.free(body);
    net.request("/api/chats/backups/snapshots", body, 0, onSnapshotsDone, .{});
}

fn onSnapshotsDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (store.undo.mode != .snapshots) return;
    store.undo.setBusy(false);
    if (res == null or status < 200 or status >= 300) {
        store.undo.setNote("Could not load snapshots.");
        regions.bumpMessageLog();
        return;
    }
    const parsed = res.?.json(SnapshotsResp) catch {
        store.undo.setNote("Could not read snapshots.");
        regions.bumpMessageLog();
        return;
    };
    defer parsed.deinit();
    store.undo.setToken(parsed.value.change_token);
    for (parsed.value.snapshots) |s| store.undo.addSnapshot(.{
        .backup_ts = s.backup_ts,
        .message_count = s.message_count,
        .last_mes_preview = s.last_mes_preview,
        .added = s.added,
        .removed = s.removed,
        .edited = s.edited,
        .too_large = s.too_large,
    });
    if (store.undo.snapshots.items.len == 0) store.undo.setNote("No snapshots yet.");
    regions.bumpMessageLog();
}

fn restoreSnapshot(backup_ts: []const u8) void {
    if (store.undo.mode != .snapshots) return;
    const id = currentIdent() orelse return;
    store.undo.setBusy(true);
    regions.bumpMessageLog();
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = id.avatar,
        .file_name = id.file,
        .mode = "restore",
        .backup_ts = backup_ts,
        .change_token = store.undo.change_token,
    }, .{}) catch return failRestore();
    defer alloc.free(body);
    net.request("/api/chats/backups/snapshots", body, 0, onRestoreDone, .{});
}

fn restoreDeleted(backup_ts: []const u8) void {
    if (store.undo.mode != .snapshots) return;
    const id = currentIdent() orelse return;
    store.undo.setBusy(true);
    regions.bumpMessageLog();
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .avatar_url = id.avatar,
        .file_name = id.file,
        .backup_ts = backup_ts,
        .change_token = store.undo.change_token,
    }, .{}) catch return failRestore();
    defer alloc.free(body);
    net.request("/api/chats/backups/restore-deleted", body, 0, onRestoreDone, .{});
}

// ---- shared restore completion -------------------------------------------------------------

/// Restore succeeded: the chat file changed, so close the surface and re-sync the reader to the fresh
/// tail through its existing 409 path. A 409 means a concurrent save moved the token; keep the surface
/// open with a note so the user reopens against fresh data.
fn onRestoreDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (status == 409) {
        store.undo.setBusy(false);
        store.undo.setNote("Chat changed since you opened this. Close and reopen to see the latest.");
        regions.bumpMessageLog();
        return;
    }
    if (status < 200 or status >= 300) {
        store.undo.setBusy(false);
        store.undo.setNote("Restore failed.");
        regions.bumpMessageLog();
        return;
    }
    log.info("undo restore applied; re-syncing the reader to the tail", .{});
    store.undo.close();
    regions.bumpMessageLog();
    pager.beginResync();
    char_api.reloadCurrentChat();
}

fn failRestore() void {
    store.undo.setBusy(false);
    store.undo.setNote("Could not restore.");
    regions.bumpMessageLog();
}

/// Render a backup timestamp "YYYYMMDD-HHMMSS" as "YYYY-MM-DD HH:MM"; returns the raw string when it
/// is not that shape. Shared by both undo surfaces for their version/snapshot captions.
pub fn fmtTs(allocator: std.mem.Allocator, ts: []const u8) []const u8 {
    if (ts.len != 15 or ts[8] != '-') return ts;
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s} {s}:{s}", .{
        ts[0..4], ts[4..6], ts[6..8], ts[9..11], ts[11..13],
    }) catch ts;
}

/// One-line change summary for a snapshot row. When the diff was too large to compute, the counts are
/// omitted rather than shown as zeroes.
pub fn snapMeta(allocator: std.mem.Allocator, s: store.Snapshot) []const u8 {
    if (s.too_large) {
        return std.fmt.allocPrint(allocator, "{d} messages, changes not counted", .{s.message_count}) catch "";
    }
    return std.fmt.allocPrint(allocator, "{d} messages, +{d} / -{d}, {d} edited", .{
        s.message_count, s.added, s.removed, s.edited,
    }) catch "";
}

// ---- DOM handlers (one per hydrated MessageLog region root) ---------------------------------

/// The MessageLog region's click handler: the undo controls (history toggle, restore actions, close)
/// come first, then a click outside an open surface dismisses it, then the panel-dismiss delegate. All
/// controls carry data-* attributes rather than their own onclick, so ziex's body-delegated dispatch
/// resolves them here (ZX11) off event.target.
pub fn onLogClick(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse {
        ui.onPageClick(ev);
        return;
    };

    if (dom_event.datasetUp(target, "undoRestore")) |ts| {
        defer zx.allocator.free(ts);
        const kind = dom_event.datasetUp(target, "undoKind") orelse "";
        defer if (kind.len > 0) zx.allocator.free(kind);
        if (std.mem.eql(u8, kind, "snapshot")) {
            restoreSnapshot(ts);
        } else if (std.mem.eql(u8, kind, "deleted")) {
            restoreDeleted(ts);
        } else {
            restoreVersion(ts);
        }
        return;
    }
    if (dom_event.datasetUp(target, "undoHistory")) |idx_str| {
        defer zx.allocator.free(idx_str);
        const abs = std.fmt.parseInt(usize, idx_str, 10) catch return;
        captureAnchor(target);
        openVersionsFor(abs);
        return;
    }
    if (dom_event.datasetUp(target, "undoClose")) |flag| {
        zx.allocator.free(flag);
        store.undo.close();
        regions.bumpMessageLog();
        return;
    }

    // A click outside an open surface (and not on a control above) dismisses it.
    if (store.undo.mode != .closed and !dom_event.hasAncestorId(target, "undo-surface")) {
        store.undo.close();
        regions.bumpMessageLog();
    }
    ui.onPageClick(ev);
}

/// The MessageLog region's keydown handler: Escape closes an open undo surface first, then the panel
/// Escape delegate runs.
pub fn onLogKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    if (store.undo.mode != .closed) {
        const key = ev.key() orelse {
            ui.onPageKey(ev);
            return;
        };
        defer zx.allocator.free(key);
        if (std.mem.eql(u8, key, "Escape")) {
            store.undo.close();
            regions.bumpMessageLog();
            return;
        }
    }
    ui.onPageKey(ev);
}

/// Move focus into the just-opened surface so Escape reaches the MessageLog handler even when the
/// trigger lived in another region (the composer Options button), and the reader gets modal focus
/// (WD39). The bump re-rendered synchronously, so the element is already in the DOM.
fn focusSurface() void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(alloc, "undo-surface") orelse return;
    defer el.deinit();
    el.ref.call(void, "focus", .{}) catch {};
}

/// Record where the version popover should sit: just under the clicked control and right-aligned to
/// it. Read from the control's viewport rect, because the popover renders fixed at the MessageLog root
/// (a `.mes`-local absolute popover is clipped by the message's paint containment).
fn captureAnchor(el: js.Object) void {
    if (zx.platform.role != .client) return;
    const rect = el.call(js.Object, "getBoundingClientRect", .{}) catch return;
    defer rect.deinit();
    const bottom = rect.get(f64, "bottom") catch return;
    const right = rect.get(f64, "right") catch return;
    const inner_w = js.global.get(f64, "innerWidth") catch return;
    store.undo.setAnchor(@floatCast(bottom + 6), @floatCast(inner_w - right));
}

/// Inline `position: fixed` placement for the version popover, from the captured anchor.
pub fn anchorStyle(allocator: std.mem.Allocator, top: f32, right: f32) []const u8 {
    return std.fmt.allocPrint(allocator, "position:fixed;top:{d}px;right:{d}px", .{
        @as(i32, @intFromFloat(top)), @as(i32, @intFromFloat(right)),
    }) catch "position:fixed;top:64px;right:16px";
}
