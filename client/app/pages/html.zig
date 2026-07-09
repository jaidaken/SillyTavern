//! The one boundary between untrusted bytes and the raw-HTML sink.
//!
//! `SanitizedHtml` carries a witness pointer to a file-private opaque type, so no other file can
//! write the struct literal. `sanitizeHtml` is the only function in the program that returns one,
//! and every path through it crosses the door's DOMPurify pass. `sink` is the only function that
//! unwraps one, and it accepts nothing else, so `@escaping={.none}` cannot be fed a bare slice.
//!
//! ziex cannot enforce this at the `.zx` boundary: `x.zig:126 expr(val: anytype)` accepts any
//! `[]const u8` and never type-checks the raw-HTML child. The gate therefore lives in the Zig layer
//! feeding the sink, and `unit_test.zig` asserts against the `.zx` sources that every
//! `@escaping={.none}` element is fed by `html.sink(`.
//!
//! HONEST LIMIT: `.witness_token = undefined` compiles, and Zig has no field privacy. The type
//! stops a convention slip, not a determined author, and any bypass is a one-line grep.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// Rendered server-side in place of message bodies; the client render replaces it.
pub const ssr_placeholder = "ST_SSR_PLACEHOLDER";

extern "env" fn sanitize(ptr: [*]const u8, len: usize) u64;

const Witness = opaque {};
var witness_anchor: u8 = 0;

fn witness() *const Witness {
    return @ptrCast(&witness_anchor);
}

/// HTML that has crossed the door's DOMPurify pass. The only value the raw-HTML sink accepts.
pub const SanitizedHtml = struct {
    bytes: []const u8,
    witness_token: *const Witness,
};

/// The raw-HTML sink. Its parameter type is the whole point: a `[]const u8` will not compile here.
pub fn sink(html: SanitizedHtml) []const u8 {
    return html.bytes;
}

/// The door packs its result as `(ptr << 32) | len`, and returns 0 for an empty result, having
/// allocated nothing. `__zx_alloc` draws from `std.heap.wasm_allocator`, so the door buffer is
/// released here once its bytes are copied. Without this, streaming leaks one buffer per token.
fn adopt(allocator: std.mem.Allocator, packed_result: u64) []const u8 {
    const addr: usize = @intCast(packed_result >> 32);
    if (addr == 0) return "";
    const len: usize = @intCast(packed_result & 0xFFFF_FFFF);
    const door_buf = @as([*]u8, @ptrFromInt(addr))[0..len];
    defer std.heap.wasm_allocator.free(door_buf);
    return allocator.dupe(u8, door_buf) catch "";
}

/// The sole mint. Every `SanitizedHtml` in the program is born here, downstream of DOMPurify.
pub fn sanitizeHtml(allocator: std.mem.Allocator, raw: []const u8) SanitizedHtml {
    if (comptime !is_wasm) return .{ .bytes = ssr_placeholder, .witness_token = witness() };
    if (raw.len == 0) return .{ .bytes = "", .witness_token = witness() };
    return .{ .bytes = adopt(allocator, sanitize(raw.ptr, raw.len)), .witness_token = witness() };
}

/// Rendered HTML keyed by a hash of the source body, with the source retained so a hash collision
/// is detected rather than silently serving another message's HTML.
///
/// Entries are never evicted. ziex keeps the previous vtree to diff against and those vnodes hold
/// these exact pointers, so freeing an entry would dangle. The cache is bounded by the number of
/// distinct message bodies; the streaming tail is not cached at all.
const Entry = struct { src: []const u8, html: SanitizedHtml };
var cache: std.HashMapUnmanaged(u64, Entry, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage) = .empty;

fn key(body: []const u8) u64 {
    return std.hash.Wyhash.hash(0, body);
}

pub fn cacheGet(body: []const u8) ?SanitizedHtml {
    const entry = cache.get(key(body)) orelse return null;
    if (!std.mem.eql(u8, entry.src, body)) return null;
    return entry.html;
}

/// `body` must be owned by the store for the life of the page: the entry retains this pointer.
pub fn cachePut(body: []const u8, html: SanitizedHtml) void {
    cache.put(std.heap.wasm_allocator, key(body), .{ .src = body, .html = html }) catch retain(html);
}

/// The streaming tail renders fresh HTML every frame, and ziex adopts that pointer into the vtree,
/// then reads it back as `old_text` while diffing the NEXT render. So a generation stays live for
/// exactly one render after the render that superseded it: `tick` retires it one render late.
pub const RetireRing = struct {
    allocator: std.mem.Allocator,
    prev: std.ArrayList([]const u8) = .empty,
    cur: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *RetireRing) void {
        for (self.prev.items) |buf| self.allocator.free(buf);
        for (self.cur.items) |buf| self.allocator.free(buf);
        self.prev.deinit(self.allocator);
        self.cur.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn tick(self: *RetireRing) void {
        for (self.prev.items) |buf| self.allocator.free(buf);
        self.prev.clearRetainingCapacity();
        std.mem.swap(std.ArrayList([]const u8), &self.prev, &self.cur);
    }

    pub fn retain(self: *RetireRing, bytes: []const u8) void {
        if (bytes.len == 0) return;
        // Freeing now would dangle the vtree pointer, so an OOM here can only strand this buffer.
        self.cur.append(self.allocator, bytes) catch {};
    }
};

const ring_gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;
var ring: RetireRing = .{ .allocator = ring_gpa };

/// Call once at the top of the render, before any `sanitizeHtml`.
pub fn renderTick() void {
    ring.tick();
}

pub fn retain(html: SanitizedHtml) void {
    ring.retain(html.bytes);
}

const testing = std.testing;

/// `@typeInfo().decls` lists public declarations only, which is the view every other file gets.
fn isPublic(comptime name: []const u8) bool {
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        if (comptime std.mem.eql(u8, decl.name, name)) return true;
    }
    return false;
}

test "sink_accepts_only_the_sanitized_witness_type" {
    const params = @typeInfo(@TypeOf(sink)).@"fn".params;
    try testing.expectEqual(@as(usize, 1), params.len);
    try testing.expectEqual(SanitizedHtml, params[0].type.?);
}

test "sanitize_html_is_the_only_public_producer_of_sanitized_html" {
    comptime var producers: []const []const u8 = &.{};
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const T = @TypeOf(@field(@This(), decl.name));
        if (@typeInfo(T) != .@"fn") continue;
        if (@typeInfo(T).@"fn".return_type != SanitizedHtml) continue;
        producers = producers ++ [_][]const u8{decl.name};
    }
    try testing.expectEqual(@as(usize, 1), producers.len);
    try testing.expectEqualStrings("sanitizeHtml", producers[0]);
}

test "the_witness_type_is_unnameable_outside_this_file" {
    // A struct literal elsewhere cannot spell this field's type, so it cannot build the witness.
    const field = @typeInfo(SanitizedHtml).@"struct".fields[1];
    try testing.expectEqualStrings("witness_token", field.name);
    try testing.expect(@typeInfo(@typeInfo(field.type).pointer.child) == .@"opaque");
    try testing.expect(!isPublic("Witness"));
    try testing.expect(isPublic("SanitizedHtml"));
}

test "sanitize_html_on_the_server_yields_the_placeholder_the_client_replaces" {
    const got = sanitizeHtml(testing.allocator, "<img src=x onerror=alert(1)>");
    try testing.expectEqualStrings(ssr_placeholder, sink(got));
}

/// Counts frees so a test can pin exactly which render retires a generation.
const Counting = struct {
    child: std.mem.Allocator,
    frees: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{ .alloc = a, .resize = r, .remap = m, .free = f };

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn a(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, al, ra);
    }
    fn r(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(mem, al, n, ra);
    }
    fn m(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(mem, al, n, ra);
    }
    fn f(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.child.rawFree(mem, al, ra);
    }
};

test "retire_ring_frees_a_generation_exactly_one_render_after_it_is_superseded" {
    var counting = Counting{ .child = testing.allocator };
    const gpa = counting.allocator();

    var r = RetireRing{ .allocator = gpa };
    defer r.deinit();

    const first = try gpa.dupe(u8, "<p>render one</p>");
    r.retain(first);
    try testing.expectEqual(@as(usize, 0), counting.frees);

    // The render that adopts a new pointer must still be able to read the previous one.
    r.tick();
    try testing.expectEqual(@as(usize, 0), counting.frees);

    const second = try gpa.dupe(u8, "<p>render two</p>");
    r.retain(second);
    r.tick();
    try testing.expectEqual(@as(usize, 1), counting.frees);
    try testing.expectEqualStrings("<p>render two</p>", second);

    r.tick();
    try testing.expectEqual(@as(usize, 2), counting.frees);
}

test "retire_ring_ignores_an_empty_generation" {
    var r = RetireRing{ .allocator = testing.allocator };
    defer r.deinit();

    r.retain("");
    r.tick();
    r.tick();
    try testing.expectEqual(@as(usize, 0), r.prev.items.len);
}

test "retire_ring_frees_every_outstanding_generation_at_deinit" {
    var counting = Counting{ .child = testing.allocator };
    const gpa = counting.allocator();

    var r = RetireRing{ .allocator = gpa };
    r.retain(try gpa.dupe(u8, "a"));
    r.tick();
    r.retain(try gpa.dupe(u8, "b"));
    r.deinit();

    // Two generations plus the two ArrayList backing buffers.
    try testing.expectEqual(@as(usize, 4), counting.frees);
}
