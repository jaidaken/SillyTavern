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
};

pub const Store = struct {
    allocator: Allocator,
    messages: std.ArrayList(Message) = .empty,
    tail: std.ArrayList(u8) = .empty,
    /// Index of the message currently receiving tokens. An index, not a pointer: `messages` moves
    /// when it grows, and a message may be appended behind the streaming one.
    stream_index: ?usize = null,

    pub fn init(allocator: Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.messages.items) |m| {
            if (m.name_owned) |b| self.allocator.free(b);
            if (m.body_owned) |b| self.allocator.free(b);
            if (m.avatar_owned) |b| self.allocator.free(b);
        }
        self.messages.deinit(self.allocator);
        self.tail.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Store) void {
        for (self.messages.items) |m| {
            if (m.name_owned) |b| self.allocator.free(b);
            if (m.body_owned) |b| self.allocator.free(b);
            if (m.avatar_owned) |b| self.allocator.free(b);
        }
        self.messages.clearRetainingCapacity();
        self.tail.deinit(self.allocator);
        self.tail = .empty;
        self.stream_index = null;
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

    /// Seals the tail into the streaming message, which owns it from here on. After this the body
    /// never moves and is never freed until `deinit`.
    pub fn endStream(self: *Store) void {
        const index = self.stream_index orelse return;
        self.stream_index = null;

        const msg = &self.messages.items[index];
        if (self.tail.items.len == 0) {
            self.tail.deinit(self.allocator);
            self.tail = .empty;
            msg.body = "";
            return;
        }

        const full = self.tail.allocatedSlice();
        const len = self.tail.items.len;
        self.tail = .empty;

        // remap may relocate rather than shrink in place, and nothing retains the pre-seal pointer,
        // so either outcome is correct. Its refusal keeps the spare capacity, freed at deinit.
        if (self.allocator.remap(full, len)) |shrunk| {
            msg.body = shrunk;
            msg.body_owned = shrunk;
        } else {
            msg.body = full[0..len];
            msg.body_owned = full;
        }
    }
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
    inline for (.{ @intFromPtr(m.name.ptr), m.name.len, @intFromPtr(m.body.ptr), m.body.len, @intFromPtr(m.avatar.ptr), m.avatar.len }) |v| {
        h = (h ^ @as(u64, v)) *% 0x100000001b3;
    }
    return h | 1;
}

pub fn clearStore() void {
    return global.clear();
}

pub fn appendCopy(name: []const u8, body: []const u8, avatar: []const u8) Allocator.Error!void {
    return global.appendCopy(name, body, avatar);
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
