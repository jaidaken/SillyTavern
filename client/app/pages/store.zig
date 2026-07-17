//! The chat log, and the sole owner of every message's text lifetime.
//!
//! Append-only: once a message is in the log its `name` stays at a fixed address for the life of
//! the store, and its `body` stays at a fixed address from the moment the message is sealed. Only
//! the streaming message's body grows, and it is sealed the moment the stream ends.
//!
//! ziex's patched vdom re-points a text node to the current render's pointer on every render, and
//! reads the previous render's pointer as `old_text` while diffing. Anything the store hands to a
//! vtree node, or to the render cache, therefore has to outlive at least the next render. Owning
//! the text for the life of the message discharges that obligation by construction.
//!
//! This module is pure Zig on purpose: no `zx`, no wasm externs. The four door entry points live
//! in `bridge.zig`, which keeps the store drivable by the native test suite under a
//! safety-checked allocator.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// A message in the log. `name_owned` and `body_owned` are the backing allocations, and are null
/// for a static fixture whose text is a literal.
pub const Message = struct {
    name: []const u8,
    body: []const u8,
    avatar: []const u8 = "",
    name_owned: ?[]u8 = null,
    body_owned: ?[]u8 = null,
    avatar_owned: ?[]u8 = null,
    /// A system turn (a narrator note, a hide marker) rather than a character or user turn. Defaults
    /// false so every construction path carries a value; the chat loader and the hide action set it.
    is_system: bool = false,
    /// Earlier generations of this turn, newest last. Empty until the swipe action lands; borrowed,
    /// never owned by the store this phase (no construction path allocates it yet).
    swipes: []const []const u8 = &.{},
    /// The model's thinking text for this turn (extra.reasoning in the chat file), owned like the
    /// body. Empty for a turn without one; rendered as collapsed chrome outside the sanitized body.
    reasoning: []const u8 = "",
    reasoning_owned: ?[]u8 = null,
};

pub const Store = struct {
    allocator: Allocator,
    messages: std.ArrayList(Message) = .empty,
    tail: std.ArrayList(u8) = .empty,
    /// The streaming message's thinking text, accumulated apart from `tail` (a think-tag split in
    /// generate routes each chunk to one or the other) and sealed alongside it in `endStream`.
    reasoning_tail: std.ArrayList(u8) = .empty,
    /// Index of the message currently receiving tokens. An index, not a pointer: `messages` moves
    /// when it grows, and a message may be appended behind the streaming one.
    stream_index: ?usize = null,
    /// Absolute index of `messages[0]` in the full chat. The reader shows a tail window, so the
    /// on-screen store is a suffix of the file; `window_offset + storeIndex` is the stable render
    /// key, so a prepend that shifts every message down leaves each one's key unchanged.
    window_offset: usize = 0,
    /// Store index of the first message appended THIS session (a send or a streamed reply). Messages
    /// below it are file-loaded history (silent to a screen reader); at or above it are live.
    session_start: usize = 0,

    pub fn init(allocator: Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.messages.items) |m| {
            if (m.name_owned) |b| self.allocator.free(b);
            if (m.body_owned) |b| self.allocator.free(b);
            if (m.avatar_owned) |b| self.allocator.free(b);
            if (m.reasoning_owned) |b| self.allocator.free(b);
        }
        self.messages.deinit(self.allocator);
        self.tail.deinit(self.allocator);
        self.reasoning_tail.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Store) void {
        for (self.messages.items) |m| {
            if (m.name_owned) |b| self.allocator.free(b);
            if (m.body_owned) |b| self.allocator.free(b);
            if (m.avatar_owned) |b| self.allocator.free(b);
            if (m.reasoning_owned) |b| self.allocator.free(b);
        }
        self.messages.clearRetainingCapacity();
        self.tail.deinit(self.allocator);
        self.tail = .empty;
        self.reasoning_tail.deinit(self.allocator);
        self.reasoning_tail = .empty;
        self.stream_index = null;
        self.window_offset = 0;
        self.session_start = 0;
    }

    pub fn slice(self: *const Store) []const Message {
        return self.messages.items;
    }

    /// True only for the message receiving tokens. Its body moves as the tail grows, so it must
    /// never be render-cached by the pointer the cache would retain.
    pub fn isStreaming(self: *const Store, index: usize) bool {
        const streaming = self.stream_index orelse return false;
        return streaming == index;
    }

    /// Takes ownership of `name`, `body`, and `avatar` on success. On failure the caller still owns them.
    pub fn append(self: *Store, name: []u8, body: []u8, avatar: []u8) Allocator.Error!void {
        try self.messages.append(self.allocator, .{
            .name = name,
            .body = body,
            .avatar = avatar,
            .name_owned = name,
            .body_owned = body,
            .avatar_owned = avatar,
        });
    }

    /// Copies `name`, `body`, and `avatar`. For callers holding literals or borrowed bytes.
    pub fn appendCopy(self: *Store, name: []const u8, body: []const u8, avatar: []const u8) Allocator.Error!void {
        const n = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(n);
        const b = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(b);
        const a = try self.allocator.dupe(u8, avatar);
        errdefer self.allocator.free(a);
        try self.append(n, b, a);
    }

    /// Copies every field including the thinking text. The chat loader's path for a stored turn
    /// that carries extra.reasoning; `appendCopy` stays the reasoning-free path and is untouched.
    pub fn appendCopyFull(self: *Store, name: []const u8, body: []const u8, avatar: []const u8, reasoning_text: []const u8) Allocator.Error!void {
        const n = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(n);
        const b = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(b);
        const a = try self.allocator.dupe(u8, avatar);
        errdefer self.allocator.free(a);
        const r: ?[]u8 = if (reasoning_text.len > 0) try self.allocator.dupe(u8, reasoning_text) else null;
        errdefer if (r) |x| self.allocator.free(x);
        try self.messages.append(self.allocator, .{
            .name = n,
            .body = b,
            .avatar = a,
            .name_owned = n,
            .body_owned = b,
            .avatar_owned = a,
            .reasoning = if (r) |x| x else "",
            .reasoning_owned = r,
        });
    }

    /// Takes ownership of `name` and `avatar` on success. Any in-flight stream is sealed first, so a second
    /// stream can never alias the first message's body.
    pub fn beginStream(self: *Store, name: []u8, avatar: []u8) Allocator.Error!void {
        self.endStream();
        try self.messages.append(self.allocator, .{ .name = name, .body = "", .avatar = avatar, .name_owned = name, .avatar_owned = avatar });
        self.stream_index = self.messages.items.len - 1;
    }

    /// Grows the streaming message's body. The tail buffer may move here, which is safe because
    /// nothing outside the store retains a streaming body across a render: it is never cached, and
    /// only the rendered HTML reaches the vtree.
    pub fn appendTail(self: *Store, bytes: []const u8) Allocator.Error!void {
        const index = self.stream_index orelse return;
        try self.tail.appendSlice(self.allocator, bytes);
        self.messages.items[index].body = self.tail.items;
    }

    /// Grows the streaming message's thinking text. Same safety story as `appendTail`: the buffer
    /// may move, and nothing outside the store retains a streaming pointer across a render.
    pub fn appendReasoningTail(self: *Store, bytes: []const u8) Allocator.Error!void {
        const index = self.stream_index orelse return;
        try self.reasoning_tail.appendSlice(self.allocator, bytes);
        self.messages.items[index].reasoning = self.reasoning_tail.items;
    }

    /// Reserves room for `body_n` body bytes and `reason_n` reasoning bytes, so a caller can stage
    /// one token's two appends with no failure point between them splitting the token.
    pub fn reserveTails(self: *Store, body_n: usize, reason_n: usize) Allocator.Error!void {
        try self.tail.ensureUnusedCapacity(self.allocator, body_n);
        try self.reasoning_tail.ensureUnusedCapacity(self.allocator, reason_n);
    }

    /// Drops trailing whitespace from the streaming reasoning text. The stream splitter calls this
    /// at the close tag, so the sealed reasoning matches the non-stream parse's trimmed capture.
    pub fn trimReasoningTail(self: *Store) void {
        const index = self.stream_index orelse return;
        const trimmed = std.mem.trimEnd(u8, self.reasoning_tail.items, &std.ascii.whitespace);
        self.reasoning_tail.shrinkRetainingCapacity(trimmed.len);
        self.messages.items[index].reasoning = self.reasoning_tail.items;
    }

    /// Seals both tails into the streaming message, which owns them from here on. After this the
    /// body and reasoning never move and are never freed until `deinit`.
    pub fn endStream(self: *Store) void {
        const index = self.stream_index orelse return;
        self.stream_index = null;

        const msg = &self.messages.items[index];
        self.seal(&self.tail, &msg.body, &msg.body_owned);
        self.seal(&self.reasoning_tail, &msg.reasoning, &msg.reasoning_owned);
    }

    fn seal(self: *Store, buf: *std.ArrayList(u8), text: *[]const u8, owned: *?[]u8) void {
        if (buf.items.len == 0) {
            buf.deinit(self.allocator);
            buf.* = .empty;
            text.* = "";
            return;
        }

        const full = buf.allocatedSlice();
        const len = buf.items.len;
        buf.* = .empty;

        // remap may relocate rather than shrink in place, and nothing retains the pre-seal pointer,
        // so either outcome is correct. Its refusal keeps the spare capacity, freed at deinit.
        if (self.allocator.remap(full, len)) |shrunk| {
            text.* = shrunk;
            owned.* = shrunk;
        } else {
            text.* = full[0..len];
            owned.* = full;
        }
    }

    /// Marks every message currently in the log as file-loaded history, so a screen reader stays
    /// silent on them. Called once a chat-open finishes seeding the window.
    pub fn markAllHistory(self: *Store) void {
        self.session_start = self.messages.items.len;
    }

    /// Copies an older batch to the head of the log in one insert, preserving every existing
    /// message's address and its `window_offset + index` key. `session_start` and any live stream
    /// index shift down by the batch length; `window_offset` shifts up by it. On failure nothing
    /// is inserted and the caller's items are untouched.
    pub fn prependSealed(self: *Store, items: []const Incoming) Allocator.Error!void {
        if (items.len == 0) return;
        const batch = try self.allocator.alloc(Message, items.len);
        var filled: usize = 0;
        errdefer {
            for (batch[0..filled]) |m| {
                if (m.name_owned) |b| self.allocator.free(b);
                if (m.body_owned) |b| self.allocator.free(b);
                if (m.avatar_owned) |b| self.allocator.free(b);
                if (m.reasoning_owned) |b| self.allocator.free(b);
            }
            self.allocator.free(batch);
        }
        for (items, 0..) |it, k| {
            const n = try self.allocator.dupe(u8, it.name);
            errdefer self.allocator.free(n);
            const b = try self.allocator.dupe(u8, it.body);
            errdefer self.allocator.free(b);
            const a = try self.allocator.dupe(u8, it.avatar);
            errdefer self.allocator.free(a);
            const r: ?[]u8 = if (it.reasoning.len > 0) try self.allocator.dupe(u8, it.reasoning) else null;
            errdefer if (r) |x| self.allocator.free(x);
            batch[k] = .{ .name = n, .body = b, .avatar = a, .name_owned = n, .body_owned = b, .avatar_owned = a, .reasoning = if (r) |x| x else "", .reasoning_owned = r };
            filled = k + 1;
        }
        try self.messages.insertSlice(self.allocator, 0, batch);
        self.allocator.free(batch);
        if (self.stream_index) |*si| si.* += items.len;
        self.session_start += items.len;
        self.window_offset -= items.len;
    }

    /// Replace the body of the sealed message at store index `i` with an owned copy of `text`, freeing
    /// the prior body. A no-op on a bad index or on the streaming message (its body aliases the tail
    /// buffer, which the next token would overwrite). The new body has a fresh address, so its render
    /// signal changes and the reconciler re-renders it. On OOM the old body is kept.
    pub fn editBody(self: *Store, i: usize, text: []const u8) Allocator.Error!void {
        if (i >= self.messages.items.len) return;
        if (self.stream_index) |si| if (si == i) return;
        const copy = try self.allocator.dupe(u8, text);
        const m = &self.messages.items[i];
        if (m.body_owned) |b| self.allocator.free(b);
        m.body = copy;
        m.body_owned = copy;
    }

    /// Delete the message at store index `i`, preserving order. `session_start` drops by one when a
    /// history message went; `stream_index` follows its message (cleared if that message was the one
    /// removed). `window_offset` is untouched: the first visible message keeps its absolute slot under
    /// a file delete (a removed message's successor inherits its index), so every surviving render key
    /// stays equal to its absolute file index. A no-op on a bad index.
    pub fn removeAt(self: *Store, i: usize) void {
        if (i >= self.messages.items.len) return;
        const m = self.messages.items[i];
        if (m.name_owned) |b| self.allocator.free(b);
        if (m.body_owned) |b| self.allocator.free(b);
        if (m.avatar_owned) |b| self.allocator.free(b);
        if (m.reasoning_owned) |b| self.allocator.free(b);
        _ = self.messages.orderedRemove(i);
        if (i < self.session_start) self.session_start -= 1;
        if (self.stream_index) |si| {
            if (i == si) {
                self.stream_index = null;
            } else if (i < si) {
                self.stream_index = si - 1;
            }
        }
    }

    /// Exchange the messages at store indices `i` and `j`, moving each to the other's absolute slot.
    /// `stream_index` moves with its message. `window_offset` and `session_start` are unchanged (the
    /// count and the window start hold). A no-op on a bad index.
    pub fn swap(self: *Store, i: usize, j: usize) void {
        if (i == j or i >= self.messages.items.len or j >= self.messages.items.len) return;
        std.mem.swap(Message, &self.messages.items[i], &self.messages.items[j]);
        if (self.stream_index) |si| {
            if (si == i) {
                self.stream_index = j;
            } else if (si == j) {
                self.stream_index = i;
            }
        }
    }
};

/// A borrowed message to prepend; `prependSealed` copies each field into store-owned memory.
pub const Incoming = struct {
    name: []const u8,
    body: []const u8,
    avatar: []const u8,
    reasoning: []const u8 = "",
};

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// Bootstrap allocator for the page-lifetime globals. Everything else takes one as a parameter.
pub const page_gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;

/// The one store the page renders. `bridge.zig` drives it from the door; `messagelog.zx` reads it.
pub var global: Store = .{ .allocator = page_gpa };

pub fn slice() []const Message {
    return global.slice();
}

pub fn isStreaming(index: usize) bool {
    return global.isStreaming(index);
}

/// Reconcile-memo content signal: a hash of the name and body pointer+length. A sealed message's
/// bytes never move, so its signal is stable and the reconciler skips it; a streaming message's
/// body grows every token, so its signal changes and it is never skipped. Never 0, since 0 tells
/// the reconciler "no signal, always resolve".
pub fn signal(m: Message) u64 {
    var h: u64 = 0xcbf29ce484222325;
    inline for (.{ @intFromPtr(m.name.ptr), m.name.len, @intFromPtr(m.body.ptr), m.body.len, @intFromPtr(m.avatar.ptr), m.avatar.len, @intFromPtr(m.reasoning.ptr), m.reasoning.len }) |v| {
        h = (h ^ @as(u64, v)) *% 0x100000001b3;
    }
    return h | 1;
}

/// Memo signal for the message at `index`, folding in whether it is still streaming. A message can
/// seal without its body pointer or length moving (an in-place `remap` in `endStream`), so the
/// content signal alone can miss the streaming-to-done transition and leave `aria-busy` stuck on.
/// Perturbing the hash while streaming makes the signal change the moment the stream ends, so the
/// reconciler re-renders the message and drops its busy flag. Never 0, same as `signal`.
pub fn signalFor(index: usize, m: Message) u64 {
    var base = signal(m);
    if (global.isStreaming(index)) base = (base ^ 0x9e3779b97f4a7c15) | 1;
    // The version popover opens on ONE message. Fold the undo epoch in for that message so opening,
    // filling, or closing it re-renders it even though its sealed body never moves (memo would skip).
    if (undo.isVersionsOpenFor(global.window_offset + index)) base = ((base ^ 0x517cc1b727220a95) *% (undo.epoch | 1)) | 1;
    // The action menu opens on ONE message. Fold its epoch for that message so its trigger's
    // aria-expanded flips even though the sealed body never moves (memo would otherwise skip it).
    if (menu.isOpenFor(global.window_offset + index)) base = ((base ^ 0x2545f4914f6cdd1d) *% (menu.epoch | 1)) | 1;
    // The reasoning block toggles per message. Fold its epoch for an open one so expand/collapse
    // re-renders that message even though its sealed body and reasoning never move (memo would skip).
    if (reasoning.isOpenFor(global.window_offset + index)) base = ((base ^ 0x94d049bb133111eb) *% (reasoning.epoch | 1)) | 1;
    return base;
}

pub fn clearStore() void {
    reasoning.clearAll();
    return global.clear();
}

pub fn appendCopyFull(name: []const u8, body: []const u8, avatar: []const u8, reasoning_text: []const u8) Allocator.Error!void {
    return global.appendCopyFull(name, body, avatar, reasoning_text);
}

pub fn appendCopy(name: []const u8, body: []const u8, avatar: []const u8) Allocator.Error!void {
    return global.appendCopy(name, body, avatar);
}

/// Absolute index of the first message in the window; the render key is this plus the loop index.
pub fn windowOffset() usize {
    return global.window_offset;
}

/// Store index of the first live (this-session) message; messages below it are silent history.
pub fn sessionStart() usize {
    return global.session_start;
}

// ---- undo UI state (C4) -------------------------------------------------------------------
// Pure Zig so it unit-tests here; a fetched entry is dropped on OOM (the surface shows fewer).

pub const UndoMode = enum { closed, versions, snapshots };

/// One earlier text of a single message, newest-first, from the backup-diff endpoint.
pub const Version = struct {
    mes: []const u8,
    backup_ts: []const u8,
    matched: bool,
};

/// One whole-chat save point from the snapshot endpoint.
pub const Snapshot = struct {
    backup_ts: []const u8,
    message_count: usize,
    last_mes_preview: []const u8,
    added: usize,
    removed: usize,
    edited: usize,
    too_large: bool,
};

pub const UndoState = struct {
    allocator: Allocator,
    mode: UndoMode = .closed,
    /// Absolute index of the message whose version popover is open (only meaningful in `.versions`).
    target_index: usize = 0,
    versions: std.ArrayList(Version) = .empty,
    snapshots: std.ArrayList(Snapshot) = .empty,
    /// The undo change-token from the last versions/snapshots response, threaded into a restore. This
    /// is NOT the reader's spine version; never restore with `pager.currentToken()`.
    change_token: []u8 = &.{},
    /// A one-line status shown in the surface (a stale-retry note, or an empty-state line).
    note: []u8 = &.{},
    busy: bool = false,
    /// Bumped on every mutation so `signalFor` re-renders the open target message; see signalFor.
    epoch: u64 = 0,
    /// Viewport anchor for the version popover (px): its top edge and its gap from the viewport right.
    /// The popover renders fixed at the MessageLog root, not inside the message, because `.mes` carries
    /// content-visibility paint containment that would clip an in-message popover.
    anchor_top: f32 = 0,
    anchor_right: f32 = 0,

    fn freeVersions(self: *UndoState) void {
        for (self.versions.items) |v| {
            self.allocator.free(v.mes);
            self.allocator.free(v.backup_ts);
        }
        self.versions.clearRetainingCapacity();
    }

    fn freeSnapshots(self: *UndoState) void {
        for (self.snapshots.items) |s| {
            self.allocator.free(s.backup_ts);
            self.allocator.free(s.last_mes_preview);
        }
        self.snapshots.clearRetainingCapacity();
    }

    pub fn deinit(self: *UndoState) void {
        self.freeVersions();
        self.versions.deinit(self.allocator);
        self.freeSnapshots();
        self.snapshots.deinit(self.allocator);
        if (self.change_token.len > 0) self.allocator.free(self.change_token);
        if (self.note.len > 0) self.allocator.free(self.note);
        self.* = undefined;
    }

    fn touch(self: *UndoState) void {
        self.epoch +%= 1;
    }

    /// Open the version popover for the message at absolute index `abs`, cleared and marked busy for
    /// the fetch the caller then dispatches.
    pub fn openVersions(self: *UndoState, abs: usize) void {
        self.freeVersions();
        self.freeSnapshots();
        self.setNoteRaw("");
        self.mode = .versions;
        self.target_index = abs;
        self.busy = true;
        self.touch();
    }

    /// Open the whole-chat snapshot overlay, cleared and marked busy for the fetch the caller dispatches.
    pub fn openSnapshots(self: *UndoState) void {
        self.freeVersions();
        self.freeSnapshots();
        self.setNoteRaw("");
        self.mode = .snapshots;
        self.busy = true;
        self.touch();
    }

    pub fn close(self: *UndoState) void {
        self.mode = .closed;
        self.busy = false;
        self.freeVersions();
        self.freeSnapshots();
        self.setNoteRaw("");
        self.touch();
    }

    pub fn setBusy(self: *UndoState, b: bool) void {
        self.busy = b;
        self.touch();
    }

    pub fn setAnchor(self: *UndoState, top: f32, right: f32) void {
        self.anchor_top = top;
        self.anchor_right = right;
    }

    pub fn setToken(self: *UndoState, token: []const u8) void {
        if (self.change_token.len > 0) self.allocator.free(self.change_token);
        self.change_token = self.allocator.dupe(u8, token) catch &.{};
    }

    fn setNoteRaw(self: *UndoState, msg: []const u8) void {
        if (self.note.len > 0) self.allocator.free(self.note);
        self.note = if (msg.len > 0) (self.allocator.dupe(u8, msg) catch &.{}) else &.{};
    }

    pub fn setNote(self: *UndoState, msg: []const u8) void {
        self.setNoteRaw(msg);
        self.touch();
    }

    /// Copy a version into the list; on OOM the version is dropped.
    pub fn addVersion(self: *UndoState, mes: []const u8, backup_ts: []const u8, matched: bool) void {
        const m = self.allocator.dupe(u8, mes) catch return;
        const t = self.allocator.dupe(u8, backup_ts) catch {
            self.allocator.free(m);
            return;
        };
        self.versions.append(self.allocator, .{ .mes = m, .backup_ts = t, .matched = matched }) catch {
            self.allocator.free(m);
            self.allocator.free(t);
            return;
        };
        self.touch();
    }

    /// Copy a snapshot into the list; on OOM the snapshot is dropped.
    pub fn addSnapshot(self: *UndoState, s: Snapshot) void {
        const ts = self.allocator.dupe(u8, s.backup_ts) catch return;
        const pv = self.allocator.dupe(u8, s.last_mes_preview) catch {
            self.allocator.free(ts);
            return;
        };
        self.snapshots.append(self.allocator, .{
            .backup_ts = ts,
            .message_count = s.message_count,
            .last_mes_preview = pv,
            .added = s.added,
            .removed = s.removed,
            .edited = s.edited,
            .too_large = s.too_large,
        }) catch {
            self.allocator.free(ts);
            self.allocator.free(pv);
            return;
        };
        self.touch();
    }

    pub fn isVersionsOpenFor(self: *const UndoState, abs: usize) bool {
        return self.mode == .versions and self.target_index == abs;
    }
};

/// The one undo state the surfaces render. `undo.zig` drives it; `message.zx`/`messagelog.zx` read it.
pub var undo: UndoState = .{ .allocator = page_gpa };

// ---- message action-menu state (C-MSG) ----------------------------------------------------
// Pure Zig, no owned memory. `message_actions.zig` drives it; `message.zx`/`message_menu.zx` read it.

pub const MenuState = struct {
    /// Absolute index of the message whose action menu is open, or null when none is.
    open_index: ?usize = null,
    /// Viewport anchor for the popped list (px): its top edge and its gap from the viewport right.
    anchor_top: f32 = 0,
    anchor_right: f32 = 0,
    /// Bumped on every open/close so `signalFor` re-renders the open message's trigger; see signalFor.
    epoch: u64 = 0,

    /// Open the menu for the message at absolute index `abs`, or close it if that one is already open.
    pub fn toggle(self: *MenuState, abs: usize) void {
        if (self.open_index) |cur| {
            if (cur == abs) {
                self.close();
                return;
            }
        }
        self.open_index = abs;
        self.epoch +%= 1;
    }

    pub fn close(self: *MenuState) void {
        self.open_index = null;
        self.epoch +%= 1;
    }

    pub fn setAnchor(self: *MenuState, top: f32, right: f32) void {
        self.anchor_top = top;
        self.anchor_right = right;
    }

    pub fn isOpenFor(self: *const MenuState, abs: usize) bool {
        return self.open_index != null and self.open_index.? == abs;
    }
};

/// The one action-menu state the message chrome renders.
pub var menu: MenuState = .{};

/// True when the action menu is open for the message at absolute index `abs`.
pub fn menuOpenFor(abs: usize) bool {
    return menu.isOpenFor(abs);
}

// ---- reasoning-block UI state (3f) --------------------------------------------------------
// Pure Zig; `message_actions.zig` drives it, `message.zx` reads it. Open set per absolute index.

pub const ReasoningUiState = struct {
    allocator: Allocator,
    open: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// Bumped on every toggle so `signalFor` re-renders the affected message; see signalFor.
    epoch: u64 = 0,

    pub fn deinit(self: *ReasoningUiState) void {
        self.open.deinit(self.allocator);
        self.* = undefined;
    }

    /// Expand or collapse the block for the message at absolute index `abs`. On OOM the toggle is
    /// dropped and the block stays collapsed, which the next click retries.
    pub fn toggle(self: *ReasoningUiState, abs: usize) void {
        if (!self.open.remove(abs)) self.open.put(self.allocator, abs, {}) catch return;
        self.epoch +%= 1;
    }

    pub fn isOpenFor(self: *const ReasoningUiState, abs: usize) bool {
        return self.open.contains(abs);
    }

    /// Collapse every block. A chat open resets this: absolute indices repeat across chats, so a
    /// stale entry would render the next chat's block expanded.
    pub fn clearAll(self: *ReasoningUiState) void {
        self.open.clearRetainingCapacity();
        self.epoch +%= 1;
    }
};

/// The one reasoning-block state the message chrome renders.
pub var reasoning: ReasoningUiState = .{ .allocator = page_gpa };

/// True when the reasoning block is expanded for the message at absolute index `abs`.
pub fn reasoningOpenFor(abs: usize) bool {
    return reasoning.isOpenFor(abs);
}

const testing = std.testing;

/// Wraps an allocator and keeps the set of live allocations, so a test can assert that a pointer
/// some renderer still holds has not been freed. Detects a use-after-free by construction rather
/// than by waiting for a segfault on an unmapped page.
const Tracker = struct {
    child: Allocator,
    live: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// Sibling of `child`, never routed through it: the map must not audit its own allocations.
    map_gpa: Allocator = testing.allocator,

    const vtable: Allocator.VTable = .{
        .alloc = talloc,
        .resize = tresize,
        .remap = tremap,
        .free = tfree,
    };

    fn init(child: Allocator) Tracker {
        return .{ .child = child };
    }

    fn deinit(self: *Tracker) void {
        self.live.deinit(self.map_gpa);
    }

    fn allocator(self: *Tracker) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn talloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.live.put(self.map_gpa, @intFromPtr(p), len) catch @panic("tracker OOM");
        return p;
    }

    fn tresize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.live.put(self.map_gpa, @intFromPtr(memory.ptr), new_len) catch @panic("tracker OOM");
        return true;
    }

    fn tremap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        _ = self.live.remove(@intFromPtr(memory.ptr));
        self.live.put(self.map_gpa, @intFromPtr(p), new_len) catch @panic("tracker OOM");
        return p;
    }

    fn tfree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        _ = self.live.remove(@intFromPtr(memory.ptr));
        self.child.rawFree(memory, alignment, ra);
    }

    fn isLive(self: *Tracker, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        const p = @intFromPtr(bytes.ptr);
        var it = self.live.iterator();
        while (it.next()) |e| {
            const base = e.key_ptr.*;
            const end = base + e.value_ptr.*;
            if (p >= base and p + bytes.len <= end) return true;
        }
        return false;
    }
};

/// Models what ziex actually retains across renders: one text-node pointer per message name, and
/// the render cache's retained source pointer per non-streaming message. Both are read on every
/// later render, so both must still be live and byte-identical.
const RenderSim = struct {
    tracker: *Tracker,
    text_nodes: std.ArrayList([]const u8) = .empty,
    cache_src: std.ArrayList(?[]const u8) = .empty,

    fn deinit(self: *RenderSim, gpa: Allocator) void {
        self.text_nodes.deinit(gpa);
        self.cache_src.deinit(gpa);
    }

    fn render(self: *RenderSim, s: *const Store, gpa: Allocator) !void {
        const msgs = s.slice();
        while (self.text_nodes.items.len < msgs.len) try self.text_nodes.append(gpa, "");
        while (self.cache_src.items.len < msgs.len) try self.cache_src.append(gpa, null);

        for (msgs, 0..) |m, i| {
            const old = self.text_nodes.items[i];
            try testing.expect(self.tracker.isLive(old));
            if (old.len != 0) try testing.expectEqualStrings(old, m.name);
            self.text_nodes.items[i] = m.name;

            if (s.isStreaming(i)) continue;
            if (self.cache_src.items[i]) |src| {
                try testing.expect(self.tracker.isLive(src));
                try testing.expectEqual(src.ptr, m.body.ptr);
                try testing.expectEqualStrings(src, m.body);
            } else {
                self.cache_src.items[i] = m.body;
            }
        }
    }
};

test "store_keeps_older_message_text_live_while_the_tail_streams" {
    var tracker = Tracker.init(testing.allocator);
    defer tracker.deinit();
    const gpa = tracker.allocator();

    var s = Store.init(gpa);
    defer s.deinit();
    var sim = RenderSim{ .tracker = &tracker };
    defer sim.deinit(testing.allocator);

    try s.appendCopy("Seraphina", "The lantern gutters.", "");
    try s.appendCopy("You", "What is that?", "");
    try s.appendCopy("Seraphina", "A wreck, or a warning.", "");
    try sim.render(&s, testing.allocator);

    try s.beginStream(try gpa.dupe(u8, "Seraphina"), try gpa.dupe(u8, ""));
    for (0..200) |i| {
        var buf: [8]u8 = undefined;
        try s.appendTail(try std.fmt.bufPrint(&buf, "t{d} ", .{i}));
        try sim.render(&s, testing.allocator);
    }
    s.endStream();
    try sim.render(&s, testing.allocator);
    try sim.render(&s, testing.allocator);

    try testing.expectEqual(@as(usize, 4), s.slice().len);
    try testing.expectEqualStrings("The lantern gutters.", s.slice()[0].body);
    try testing.expect(std.mem.startsWith(u8, s.slice()[3].body, "t0 t1 "));
    try testing.expect(std.mem.endsWith(u8, s.slice()[3].body, "t199 "));
    try testing.expectEqual(@as(?usize, null), s.stream_index);
}

test "store_survives_a_message_appended_while_a_stream_is_running" {
    var tracker = Tracker.init(testing.allocator);
    defer tracker.deinit();
    const gpa = tracker.allocator();

    var s = Store.init(gpa);
    defer s.deinit();
    var sim = RenderSim{ .tracker = &tracker };
    defer sim.deinit(testing.allocator);

    try s.appendCopy("You", "Tell me about the shoals.", "");
    try s.beginStream(try gpa.dupe(u8, "Seraphina"), try gpa.dupe(u8, ""));

    for (0..20) |_| {
        try s.appendTail("a");
        try sim.render(&s, testing.allocator);
    }

    // The streaming message is no longer last. Keying `isStreaming` on the last index would let
    // the render cache retain the moving tail buffer, which the next append frees.
    try s.appendCopy("Narrator", "A gull cries.", "");
    try sim.render(&s, testing.allocator);

    for (0..20) |_| {
        try s.appendTail("b");
        try sim.render(&s, testing.allocator);
    }
    s.endStream();
    try sim.render(&s, testing.allocator);
    try sim.render(&s, testing.allocator);

    try testing.expectEqual(@as(usize, 3), s.slice().len);
    try testing.expectEqualStrings("a" ** 20 ++ "b" ** 20, s.slice()[1].body);
    try testing.expectEqualStrings("A gull cries.", s.slice()[2].body);
}

test "begin_stream_while_streaming_seals_the_first_body_instead_of_aliasing_it" {
    var tracker = Tracker.init(testing.allocator);
    defer tracker.deinit();
    const gpa = tracker.allocator();

    var s = Store.init(gpa);
    defer s.deinit();
    var sim = RenderSim{ .tracker = &tracker };
    defer sim.deinit(testing.allocator);

    try s.beginStream(try gpa.dupe(u8, "First"), try gpa.dupe(u8, ""));
    try s.appendTail("first body");
    try sim.render(&s, testing.allocator);

    try s.beginStream(try gpa.dupe(u8, "Second"), try gpa.dupe(u8, ""));
    try s.appendTail("second body");
    try sim.render(&s, testing.allocator);
    s.endStream();
    try sim.render(&s, testing.allocator);

    try testing.expectEqual(@as(usize, 2), s.slice().len);
    try testing.expectEqualStrings("first body", s.slice()[0].body);
    try testing.expectEqualStrings("second body", s.slice()[1].body);
    try testing.expect(s.slice()[0].body.ptr != s.slice()[1].body.ptr);
}

test "append_tail_without_a_stream_is_silent" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.appendCopy("You", "hello", "");
    try s.appendTail("dropped");

    try testing.expectEqual(@as(usize, 1), s.slice().len);
    try testing.expectEqualStrings("hello", s.slice()[0].body);
}

test "end_stream_with_no_tokens_yields_an_empty_body" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.beginStream(try testing.allocator.dupe(u8, "Seraphina"), try testing.allocator.dupe(u8, ""));
    s.endStream();

    try testing.expectEqual(@as(usize, 1), s.slice().len);
    try testing.expectEqualStrings("", s.slice()[0].body);
    try testing.expectEqual(@as(?usize, null), s.stream_index);
}

test "sealed_body_keeps_its_address_across_later_appends" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.beginStream(try testing.allocator.dupe(u8, "Seraphina"), try testing.allocator.dupe(u8, ""));
    try s.appendTail("sealed text");
    s.endStream();
    const sealed = s.slice()[0].body.ptr;

    for (0..64) |_| try s.appendCopy("You", "filler", "");

    try testing.expectEqual(sealed, s.slice()[0].body.ptr);
    try testing.expectEqualStrings("sealed text", s.slice()[0].body);
}

fn streamScenario(gpa: Allocator, tokens: usize) !void {
    var s = Store.init(gpa);
    defer s.deinit();

    try s.appendCopy("You", "one", "");

    const name = try gpa.dupe(u8, "Seraphina");
    const avatar = try gpa.dupe(u8, "");
    // Scoped to this call: past it the store owns `name`, and an errdefer would double-free.
    s.beginStream(name, avatar) catch |err| {
        gpa.free(name);
        gpa.free(avatar);
        return err;
    };

    for (0..tokens) |_| try s.appendTail("x");
    try s.appendCopy("Narrator", "mid", "");
    for (0..tokens) |_| try s.appendTail("y");
    s.endStream();

    try testing.expectEqual(tokens * 2, s.slice()[1].body.len);
}

test "store_releases_everything_on_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, streamScenario, .{@as(usize, 8)});
}

test "signal_is_stable_across_reads_of_a_sealed_message" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.beginStream(try testing.allocator.dupe(u8, "Seraphina"), try testing.allocator.dupe(u8, ""));
    try s.appendTail("a sealed line");
    s.endStream();

    const first = signal(s.slice()[0]);
    const second = signal(s.slice()[0]);
    try testing.expectEqual(first, second);

    for (0..32) |_| try s.appendCopy("You", "filler", "");
    try testing.expectEqual(first, signal(s.slice()[0]));
}

test "signal_changes_on_every_token_while_the_body_streams" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.beginStream(try testing.allocator.dupe(u8, "Seraphina"), try testing.allocator.dupe(u8, ""));

    var seen = std.AutoHashMapUnmanaged(u64, void).empty;
    defer seen.deinit(testing.allocator);

    var prev = signal(s.slice()[0]);
    try seen.put(testing.allocator, prev, {});
    for (0..200) |i| {
        var buf: [8]u8 = undefined;
        try s.appendTail(try std.fmt.bufPrint(&buf, "t{d} ", .{i}));
        const now = signal(s.slice()[0]);
        try testing.expect(now != prev);
        try seen.put(testing.allocator, now, {});
        prev = now;
    }
    // Every per-token signal was distinct, so the streaming message is never wrongly skipped.
    try testing.expectEqual(@as(u32, 201), seen.count());
}

test "signal_distinguishes_two_messages_with_different_bodies" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.appendCopy("You", "the lantern gutters", "");
    try s.appendCopy("You", "a wreck, or a warning", "");

    try testing.expect(signal(s.slice()[0]) != signal(s.slice()[1]));
}

test "signal_is_never_zero_even_for_an_empty_body" {
    const empty: Message = .{ .name = "You", .body = "" };
    try testing.expect(signal(empty) != 0);
}

fn signalScenario(gpa: Allocator) !void {
    var s = Store.init(gpa);
    defer s.deinit();

    try s.appendCopy("You", "hello", "");
    const name = try gpa.dupe(u8, "Seraphina");
    const avatarSig = try gpa.dupe(u8, "");
    s.beginStream(name, avatarSig) catch |err| {
        gpa.free(name);
        gpa.free(avatarSig);
        return err;
    };
    for (0..8) |_| {
        try s.appendTail("x");
        _ = signal(s.slice()[s.slice().len - 1]);
    }
    s.endStream();
    for (s.slice()) |m| _ = signal(m);
}

test "signal_path_leaves_no_leak_under_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, signalScenario, .{});
}

test "store_leaves_no_leak_under_a_debug_allocator" {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug.allocator();

    var s = Store.init(gpa);
    try s.appendCopy("You", "hello", "");
    try s.beginStream(try gpa.dupe(u8, "Seraphina"), try gpa.dupe(u8, ""));
    for (0..512) |_| try s.appendTail("token ");
    try s.appendCopy("Narrator", "interjection", "");
    for (0..512) |_| try s.appendTail("more ");
    s.endStream();
    try testing.expectEqual(@as(usize, 3072 + 2560), s.slice()[1].body.len);
    s.deinit();

    try testing.expectEqual(std.heap.Check.ok, debug.deinit());
}

test "mark_all_history_moves_the_session_boundary_to_the_current_length" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.appendCopy("a", "1", "");
    try s.appendCopy("b", "2", "");
    try testing.expectEqual(@as(usize, 0), s.session_start);
    s.markAllHistory();
    try testing.expectEqual(@as(usize, 2), s.session_start);
}

test "prepend_preserves_addresses_and_shifts_offset_session_and_stream" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    // A loaded window of two history messages whose first is absolute index 1000.
    s.window_offset = 1000;
    try s.appendCopy("Rita", "history one", "");
    try s.appendCopy("You", "history two", "");
    s.markAllHistory();
    // A sealed reply, then a live stream running during the prepend (the mid-stream case).
    try s.beginStream(try testing.allocator.dupe(u8, "Rita"), try testing.allocator.dupe(u8, ""));
    try s.appendTail("sealed reply");
    s.endStream();
    try s.beginStream(try testing.allocator.dupe(u8, "Rita"), try testing.allocator.dupe(u8, ""));
    try s.appendTail("streaming");

    const kept_body = s.slice()[0].body.ptr;
    const abs_key_before = s.window_offset + 0;
    const stream_before = s.stream_index.?;

    const batch = [_]Incoming{
        .{ .name = "Old", .body = "older a", .avatar = "" },
        .{ .name = "Old", .body = "older b", .avatar = "" },
        .{ .name = "Old", .body = "older c", .avatar = "" },
    };
    try s.prependSealed(&batch);

    try testing.expectEqual(@as(usize, 997), s.window_offset);
    try testing.expectEqual(@as(usize, 5), s.session_start);
    try testing.expectEqual(stream_before + 3, s.stream_index.?);
    // The kept message moved down by 3 but keeps its byte address AND its absolute key.
    try testing.expectEqual(kept_body, s.slice()[3].body.ptr);
    try testing.expectEqualStrings("history one", s.slice()[3].body);
    try testing.expectEqual(abs_key_before, s.window_offset + 3);
    try testing.expectEqualStrings("older a", s.slice()[0].body);
    try testing.expectEqualStrings("streaming", s.slice()[s.slice().len - 1].body);
}

test "prepend_of_an_empty_batch_leaves_the_store_unchanged" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    s.window_offset = 10;
    try s.appendCopy("You", "only", "");
    s.markAllHistory();
    try s.prependSealed(&.{});
    try testing.expectEqual(@as(usize, 1), s.slice().len);
    try testing.expectEqual(@as(usize, 10), s.window_offset);
    try testing.expectEqual(@as(usize, 1), s.session_start);
}

fn prependScenario(gpa: Allocator) !void {
    var s = Store.init(gpa);
    defer s.deinit();
    s.window_offset = 100;
    try s.appendCopy("You", "seed", "");
    s.markAllHistory();
    const batch = [_]Incoming{
        .{ .name = "A", .body = "older a", .avatar = "av" },
        .{ .name = "B", .body = "older b", .avatar = "av" },
    };
    try s.prependSealed(&batch);
    try testing.expectEqual(@as(usize, 3), s.slice().len);
    try testing.expectEqual(@as(usize, 98), s.window_offset);
}

test "prepend_releases_everything_on_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, prependScenario, .{});
}

test "undo_opens_versions_for_a_target_then_closes" {
    var u = UndoState{ .allocator = testing.allocator };
    defer u.deinit();
    try testing.expectEqual(UndoMode.closed, u.mode);
    u.openVersions(7);
    try testing.expectEqual(UndoMode.versions, u.mode);
    try testing.expectEqual(@as(usize, 7), u.target_index);
    try testing.expect(u.busy);
    try testing.expect(u.isVersionsOpenFor(7));
    try testing.expect(!u.isVersionsOpenFor(6));
    u.close();
    try testing.expectEqual(UndoMode.closed, u.mode);
    try testing.expect(!u.busy);
    try testing.expect(!u.isVersionsOpenFor(7));
}

test "undo_add_version_copies_bytes_and_survives_the_source_freeing" {
    var u = UndoState{ .allocator = testing.allocator };
    defer u.deinit();
    u.openVersions(1);
    var src = [_]u8{ 'l', 'i', 't' };
    u.addVersion(&src, "20260714-120000", true);
    src[0] = 'X'; // mutate the source: the stored copy must be independent
    try testing.expectEqual(@as(usize, 1), u.versions.items.len);
    try testing.expectEqualStrings("lit", u.versions.items[0].mes);
    try testing.expectEqualStrings("20260714-120000", u.versions.items[0].backup_ts);
    try testing.expect(u.versions.items[0].matched);
    u.setBusy(false);
    try testing.expect(!u.busy);
}

test "undo_open_snapshots_holds_copied_rows" {
    var u = UndoState{ .allocator = testing.allocator };
    defer u.deinit();
    u.openSnapshots();
    try testing.expectEqual(UndoMode.snapshots, u.mode);
    u.addSnapshot(.{ .backup_ts = "20260714-110000", .message_count = 4, .last_mes_preview = "the lantern gutters", .added = 0, .removed = 0, .edited = 1, .too_large = false });
    try testing.expectEqual(@as(usize, 1), u.snapshots.items.len);
    try testing.expectEqual(@as(usize, 4), u.snapshots.items[0].message_count);
    try testing.expectEqual(@as(usize, 1), u.snapshots.items[0].edited);
    try testing.expectEqualStrings("the lantern gutters", u.snapshots.items[0].last_mes_preview);
    // Reopening versions must drop the snapshot rows.
    u.openVersions(0);
    try testing.expectEqual(@as(usize, 0), u.snapshots.items.len);
}

test "undo_set_token_and_note_replace_the_prior_value" {
    var u = UndoState{ .allocator = testing.allocator };
    defer u.deinit();
    u.setToken("utok-0");
    try testing.expectEqualStrings("utok-0", u.change_token);
    u.setToken("utok-1");
    try testing.expectEqualStrings("utok-1", u.change_token);
    u.setNote("chat changed, reopen history");
    try testing.expectEqualStrings("chat changed, reopen history", u.note);
    u.setNote("");
    try testing.expectEqual(@as(usize, 0), u.note.len);
}

test "undo_epoch_advances_on_every_mutation" {
    var u = UndoState{ .allocator = testing.allocator };
    defer u.deinit();
    const e0 = u.epoch;
    u.openVersions(2);
    const e1 = u.epoch;
    try testing.expect(e1 != e0);
    u.addVersion("a", "20260714-120000", false);
    try testing.expect(u.epoch != e1);
    const e2 = u.epoch;
    u.close();
    try testing.expect(u.epoch != e2);
}

test "signalFor perturbs only the message whose version popover is open" {
    // Drives the module globals; close restores them for the tests that follow.
    defer undo.close();
    const m0: Message = .{ .name = "You", .body = "one" };
    const m1: Message = .{ .name = "You", .body = "two" };
    const base0 = signalFor(0, m0);
    const base1 = signalFor(1, m1);
    undo.openVersions(0);
    try testing.expect(signalFor(0, m0) != base0);
    try testing.expectEqual(base1, signalFor(1, m1));
}

test "undo_state_leaves_no_leak_under_a_debug_allocator" {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug.allocator();

    var u = UndoState{ .allocator = gpa };
    u.setToken("utok-0");
    u.openVersions(3);
    for (0..8) |i| {
        var buf: [8]u8 = undefined;
        u.addVersion(std.fmt.bufPrint(&buf, "v{d}", .{i}) catch "v", "20260714-120000", i % 2 == 0);
    }
    u.setNote("stale, reopened");
    u.openSnapshots();
    for (0..8) |i| {
        var buf: [8]u8 = undefined;
        u.addSnapshot(.{ .backup_ts = std.fmt.bufPrint(&buf, "2026071{d}-000000", .{i}) catch "20260714-000000", .message_count = i, .last_mes_preview = "preview", .added = i, .removed = 0, .edited = 1, .too_large = false });
    }
    u.close();
    u.deinit();

    try testing.expectEqual(std.heap.Check.ok, debug.deinit());
}

test "message defaults to not-system with no swipes" {
    const m: Message = .{ .name = "You", .body = "hi" };
    try testing.expect(!m.is_system);
    try testing.expectEqual(@as(usize, 0), m.swipes.len);
}

test "edit_body_replaces_the_text_and_changes_the_signal" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.appendCopy("You", "the lantern gutters", "");
    const before = signal(s.slice()[0]);
    try s.editBody(0, "the lantern flares");
    try testing.expectEqualStrings("the lantern flares", s.slice()[0].body);
    try testing.expect(signal(s.slice()[0]) != before);
}

test "edit_body_is_a_noop_on_a_bad_index_or_the_streaming_message" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.appendCopy("You", "sealed", "");
    try s.beginStream(try testing.allocator.dupe(u8, "Seraphina"), try testing.allocator.dupe(u8, ""));
    try s.appendTail("streaming body");
    try s.editBody(9, "ignored");
    try s.editBody(1, "must not touch the tail");
    try testing.expectEqualStrings("sealed", s.slice()[0].body);
    try testing.expectEqualStrings("streaming body", s.slice()[1].body);
    s.endStream();
}

test "edit_body_leaves_no_leak_under_a_debug_allocator" {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug.allocator();
    var s = Store.init(gpa);
    try s.appendCopy("You", "first text", "");
    for (0..16) |i| {
        var buf: [16]u8 = undefined;
        try s.editBody(0, try std.fmt.bufPrint(&buf, "revision {d}", .{i}));
    }
    try testing.expectEqualStrings("revision 15", s.slice()[0].body);
    s.deinit();
    try testing.expectEqual(std.heap.Check.ok, debug.deinit());
}

test "remove_at_deletes_the_message_and_holds_the_window_offset" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    s.window_offset = 100;
    try s.appendCopy("a", "one", "");
    try s.appendCopy("b", "two", "");
    try s.appendCopy("c", "three", "");
    s.markAllHistory();
    // A live turn on top of three history messages.
    try s.appendCopy("d", "four", "");
    try testing.expectEqual(@as(usize, 3), s.session_start);

    // Remove a history message: session_start drops, window_offset holds, the survivor after it keeps
    // its absolute file index (window_offset + new store index).
    s.removeAt(1);
    try testing.expectEqual(@as(usize, 3), s.slice().len);
    try testing.expectEqual(@as(usize, 100), s.window_offset);
    try testing.expectEqual(@as(usize, 2), s.session_start);
    try testing.expectEqualStrings("one", s.slice()[0].body);
    try testing.expectEqualStrings("three", s.slice()[1].body);
    try testing.expectEqualStrings("four", s.slice()[2].body);
}

test "remove_at_follows_and_clears_the_stream_index" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.appendCopy("a", "one", "");
    try s.beginStream(try testing.allocator.dupe(u8, "Seraphina"), try testing.allocator.dupe(u8, ""));
    try s.appendTail("streaming");
    try testing.expectEqual(@as(usize, 1), s.stream_index.?);
    // Removing a message before the stream shifts the stream index down.
    s.removeAt(0);
    try testing.expectEqual(@as(usize, 0), s.stream_index.?);
    // Removing the streaming message itself clears the index.
    s.removeAt(0);
    try testing.expectEqual(@as(?usize, null), s.stream_index);
    s.endStream();
}

test "remove_at_is_a_noop_on_a_bad_index" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.appendCopy("a", "one", "");
    s.removeAt(5);
    try testing.expectEqual(@as(usize, 1), s.slice().len);
}

test "swap_exchanges_two_messages_and_moves_the_stream_index" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    s.window_offset = 10;
    try s.appendCopy("a", "one", "");
    try s.appendCopy("b", "two", "");
    s.markAllHistory();
    try s.beginStream(try testing.allocator.dupe(u8, "c"), try testing.allocator.dupe(u8, ""));
    try s.appendTail("three");
    try testing.expectEqual(@as(usize, 2), s.stream_index.?);
    s.swap(0, 2);
    try testing.expectEqualStrings("three", s.slice()[0].body);
    try testing.expectEqualStrings("one", s.slice()[2].body);
    try testing.expectEqual(@as(usize, 0), s.stream_index.?);
    // Window start and session boundary are unchanged by a swap.
    try testing.expectEqual(@as(usize, 10), s.window_offset);
    try testing.expectEqual(@as(usize, 2), s.session_start);
    s.endStream();
}

test "swap_is_a_noop_on_equal_or_bad_indices" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.appendCopy("a", "one", "");
    try s.appendCopy("b", "two", "");
    s.swap(0, 0);
    s.swap(0, 9);
    try testing.expectEqualStrings("one", s.slice()[0].body);
    try testing.expectEqualStrings("two", s.slice()[1].body);
}

test "menu_toggles_open_and_closed_for_one_target" {
    var m = MenuState{};
    try testing.expect(!m.isOpenFor(3));
    m.toggle(3);
    try testing.expect(m.isOpenFor(3));
    try testing.expect(!m.isOpenFor(4));
    // Toggling a different target moves the open one, never opens two.
    m.toggle(4);
    try testing.expect(m.isOpenFor(4));
    try testing.expect(!m.isOpenFor(3));
    // Toggling the open target closes it.
    m.toggle(4);
    try testing.expect(!m.isOpenFor(4));
    try testing.expectEqual(@as(?usize, null), m.open_index);
}

test "menu_epoch_advances_on_open_and_close" {
    var m = MenuState{};
    const e0 = m.epoch;
    m.toggle(1);
    try testing.expect(m.epoch != e0);
    const e1 = m.epoch;
    m.close();
    try testing.expect(m.epoch != e1);
}

test "signalFor perturbs only the message whose action menu is open" {
    defer menu.close();
    const m0: Message = .{ .name = "You", .body = "one" };
    const m1: Message = .{ .name = "You", .body = "two" };
    const base0 = signalFor(0, m0);
    const base1 = signalFor(1, m1);
    menu.toggle(0);
    try testing.expect(signalFor(0, m0) != base0);
    try testing.expectEqual(base1, signalFor(1, m1));
}

test "message defaults to empty reasoning" {
    const m: Message = .{ .name = "You", .body = "hi" };
    try testing.expectEqual(@as(usize, 0), m.reasoning.len);
    try testing.expectEqual(@as(?[]u8, null), m.reasoning_owned);
}

test "append_copy_full_carries_reasoning_and_append_copy_leaves_it_empty" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.appendCopyFull("Seraphina", "the answer", "", "let me think");
    try s.appendCopy("You", "plain", "");
    try testing.expectEqualStrings("let me think", s.slice()[0].reasoning);
    try testing.expectEqualStrings("the answer", s.slice()[0].body);
    try testing.expectEqual(@as(usize, 0), s.slice()[1].reasoning.len);
}

test "edit_body_leaves_reasoning_untouched" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.appendCopyFull("Seraphina", "old body", "", "kept reasoning");
    const kept = s.slice()[0].reasoning.ptr;
    try s.editBody(0, "new body");
    try testing.expectEqualStrings("new body", s.slice()[0].body);
    try testing.expectEqualStrings("kept reasoning", s.slice()[0].reasoning);
    try testing.expectEqual(kept, s.slice()[0].reasoning.ptr);
}

test "streamed_reasoning_accumulates_and_seals_apart_from_the_body" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.beginStream(try testing.allocator.dupe(u8, "Seraphina"), try testing.allocator.dupe(u8, ""));
    try s.appendReasoningTail("thinking ");
    try s.appendTail("body ");
    try s.appendReasoningTail("more");
    try s.appendTail("text");
    s.endStream();
    try testing.expectEqualStrings("thinking more", s.slice()[0].reasoning);
    try testing.expectEqualStrings("body text", s.slice()[0].body);
    // Sealed reasoning holds its address across later appends, like the body.
    const ptr = s.slice()[0].reasoning.ptr;
    for (0..32) |_| try s.appendCopy("You", "filler", "");
    try testing.expectEqual(ptr, s.slice()[0].reasoning.ptr);
}

test "append_reasoning_tail_without_a_stream_is_silent" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.appendCopy("You", "hello", "");
    try s.appendReasoningTail("dropped");
    try testing.expectEqual(@as(usize, 0), s.slice()[0].reasoning.len);
}

test "a_second_stream_never_inherits_the_first_streams_reasoning" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.beginStream(try testing.allocator.dupe(u8, "First"), try testing.allocator.dupe(u8, ""));
    try s.appendReasoningTail("first thoughts");
    try s.appendTail("first body");
    try s.beginStream(try testing.allocator.dupe(u8, "Second"), try testing.allocator.dupe(u8, ""));
    try s.appendTail("second body");
    s.endStream();
    try testing.expectEqualStrings("first thoughts", s.slice()[0].reasoning);
    try testing.expectEqual(@as(usize, 0), s.slice()[1].reasoning.len);
}

test "signal_changes_when_reasoning_streams_in" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.beginStream(try testing.allocator.dupe(u8, "Seraphina"), try testing.allocator.dupe(u8, ""));
    const before = signal(s.slice()[0]);
    try s.appendReasoningTail("t");
    try testing.expect(signal(s.slice()[0]) != before);
    s.endStream();
}

fn reasoningScenario(gpa: Allocator) !void {
    var s = Store.init(gpa);
    defer s.deinit();
    s.window_offset = 100;
    try s.appendCopyFull("A", "body", "av", "seed reasoning");
    const name = try gpa.dupe(u8, "Seraphina");
    const av = try gpa.dupe(u8, "");
    // Scoped to this call: past it the store owns `name`, and an errdefer would double-free.
    s.beginStream(name, av) catch |err| {
        gpa.free(name);
        gpa.free(av);
        return err;
    };
    for (0..8) |_| try s.appendReasoningTail("r");
    for (0..8) |_| try s.appendTail("b");
    s.endStream();
    const batch = [_]Incoming{.{ .name = "Old", .body = "old body", .avatar = "", .reasoning = "older r" }};
    try s.prependSealed(&batch);
    try testing.expectEqualStrings("older r", s.slice()[0].reasoning);
    try testing.expectEqualStrings("seed reasoning", s.slice()[1].reasoning);
    try testing.expectEqualStrings("r" ** 8, s.slice()[2].reasoning);
    try testing.expectEqualStrings("b" ** 8, s.slice()[2].body);
}

test "reasoning_paths_release_everything_on_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, reasoningScenario, .{});
}

test "reasoning_toggle_opens_independent_targets" {
    var r = ReasoningUiState{ .allocator = testing.allocator };
    defer r.deinit();
    try testing.expect(!r.isOpenFor(3));
    r.toggle(3);
    r.toggle(5);
    try testing.expect(r.isOpenFor(3));
    try testing.expect(r.isOpenFor(5));
    r.toggle(3);
    try testing.expect(!r.isOpenFor(3));
    try testing.expect(r.isOpenFor(5));
    r.clearAll();
    try testing.expect(!r.isOpenFor(5));
}

test "signalFor perturbs only the message whose reasoning is open" {
    defer reasoning.clearAll();
    const m0: Message = .{ .name = "You", .body = "one" };
    const m1: Message = .{ .name = "You", .body = "two" };
    const base0 = signalFor(0, m0);
    const base1 = signalFor(1, m1);
    reasoning.toggle(0);
    try testing.expect(signalFor(0, m0) != base0);
    try testing.expectEqual(base1, signalFor(1, m1));
    // Collapsing returns the signal to base, so the close itself re-renders the message.
    reasoning.toggle(0);
    try testing.expectEqual(base0, signalFor(0, m0));
}

test "clear_store_collapses_every_reasoning_block" {
    defer reasoning.clearAll();
    reasoning.toggle(2);
    try testing.expect(reasoningOpenFor(2));
    clearStore();
    try testing.expect(!reasoningOpenFor(2));
}
