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

/// Rendered server-side in place of message bodies; the client render replaces it. Wrapped in a
/// `hidden` span so the raw placeholder never paints in the split second before the wasm hydrates.
pub const ssr_placeholder = "<span hidden>ST_SSR_PLACEHOLDER</span>";

extern "env" fn sanitize(ptr: [*]const u8, len: usize) u64;

/// Count of real env.sanitize invocations (raw.len > 0), read by stream_drive to fill the verify
/// gate's #probe-metrics render-cache budget. The empty-raw fast path below never calls the extern,
/// so it never counts, matching what the JS-side counter observed.
var sanitize_count: usize = 0;
pub fn sanitizes() usize {
    return sanitize_count;
}

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

/// The dupe-failure sentinel. `adopt` returns this empty slice when it cannot allocate, so that
/// `Cache.put` can tell a genuine failure (retry next render) apart from a legitimately empty
/// DOMPurify result (cache it). The address of a file-private var is unique, so no real buffer and
/// no `""` literal can alias it.
var failed_anchor: u8 = 0;

fn failedBytes() []const u8 {
    return @as([*]const u8, @ptrCast(&failed_anchor))[0..0];
}

fn isFailed(html: SanitizedHtml) bool {
    return html.bytes.ptr == @as([*]const u8, @ptrCast(&failed_anchor));
}

/// The door packs its result as `(ptr << 32) | len`, and returns 0 for an empty result, having
/// allocated nothing. `__zx_alloc` draws from `std.heap.wasm_allocator`, so the door buffer is
/// released here once its bytes are copied. Without this, streaming leaks one buffer per token.
///
/// A zero door result is a real, cacheable `""` (DOMPurify stripped the body to nothing); a failed
/// dupe is `failedBytes()`, which `Cache.put` refuses to store so the next render retries. The two
/// must not both collapse to a bare `""`, or a stripped body re-sanitizes on every render forever.
const Packed = struct { addr: usize, len: usize };

/// The pure half of `adopt`: the `(ptr << 32) | len` split. Extracted so it is testable without a
/// wasm heap, since `adopt` itself dereferences the address and frees through `wasm_allocator`.
fn unpack(packed_result: u64) Packed {
    return .{ .addr = @intCast(packed_result >> 32), .len = @intCast(packed_result & 0xFFFF_FFFF) };
}

fn adopt(allocator: std.mem.Allocator, packed_result: u64) []const u8 {
    const p = unpack(packed_result);
    if (p.addr == 0) return "";
    const door_buf = @as([*]u8, @ptrFromInt(p.addr))[0..p.len];
    defer std.heap.wasm_allocator.free(door_buf);
    return allocator.dupe(u8, door_buf) catch failedBytes();
}

/// The sole mint. Every `SanitizedHtml` in the program is born here, downstream of DOMPurify.
pub fn sanitizeHtml(allocator: std.mem.Allocator, raw: []const u8) SanitizedHtml {
    if (comptime !is_wasm) return .{ .bytes = ssr_placeholder, .witness_token = witness() };
    if (raw.len == 0) return .{ .bytes = "", .witness_token = witness() };
    sanitize_count += 1;
    return .{ .bytes = adopt(allocator, sanitize(raw.ptr, raw.len)), .witness_token = witness() };
}

/// Rendered HTML keyed by a hash of the source body, with the source retained so a hash collision
/// is detected rather than silently serving another message's HTML.
///
/// A hit is never evicted while its key is unique. ziex keeps the previous vtree to diff against
/// and those vnodes hold these exact pointers, so freeing an entry outright would dangle; the two
/// paths that do drop bytes (a colliding overwrite, a failed insert) hand them to the retire ring
/// instead. The cache is bounded by the number of distinct message bodies; the streaming tail is
/// not cached at all.
const Entry = struct { src: []const u8, html: SanitizedHtml };

const Cache = struct {
    allocator: std.mem.Allocator,
    ring: *RetireRing,
    map: std.HashMapUnmanaged(u64, Entry, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage) = .empty,

    fn deinit(self: *Cache) void {
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    fn get(self: *const Cache, body: []const u8) ?SanitizedHtml {
        const entry = self.map.get(key(body)) orelse return null;
        if (!std.mem.eql(u8, entry.src, body)) return null;
        return entry.html;
    }

    /// `k` is `key(body)` in production; a test passes it directly to stage a hash collision.
    fn put(self: *Cache, k: u64, body: []const u8, html: SanitizedHtml) void {
        // A failed sanitize has no real bytes; caching it blanks the message for the page's life, so
        // skip it and let the next render retry. A legitimately empty DOMPurify result is cached.
        if (isFailed(html)) return;

        const gop = self.map.getOrPut(self.allocator, k) catch {
            self.ring.retain(html.bytes);
            return;
        };
        // A colliding key displaces another body's bytes, which the live vtree may still point at.
        if (gop.found_existing) self.ring.retain(gop.value_ptr.html.bytes);
        gop.value_ptr.* = .{ .src = body, .html = html };
    }
};

fn key(body: []const u8) u64 {
    return std.hash.Wyhash.hash(0, body);
}

pub fn cacheGet(body: []const u8) ?SanitizedHtml {
    return cache.get(body);
}

/// `body` must be owned by the store for the life of the page: the entry retains this pointer.
pub fn cachePut(body: []const u8, html: SanitizedHtml) void {
    cache.put(key(body), body, html);
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

/// Both hold bytes for the life of the page, so neither draws from the per-render allocator.
const static_gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;
var ring: RetireRing = .{ .allocator = static_gpa };
var cache: Cache = .{ .allocator = static_gpa, .ring = &ring };

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

/// A witness reaches a caller through an optional or an error union just as well as bare, so the
/// producer scan has to see through both or a `fn f() ?SanitizedHtml` mint would go uncounted.
fn yieldsSanitizedHtml(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |opt| yieldsSanitizedHtml(opt.child),
        .error_union => |eu| yieldsSanitizedHtml(eu.payload),
        else => T == SanitizedHtml,
    };
}

test "yields_sanitized_html_sees_through_optionals_and_error_unions" {
    try testing.expect(yieldsSanitizedHtml(SanitizedHtml));
    try testing.expect(yieldsSanitizedHtml(?SanitizedHtml));
    try testing.expect(yieldsSanitizedHtml(error{Oom}!SanitizedHtml));
    try testing.expect(yieldsSanitizedHtml(error{Oom}!?SanitizedHtml));
    try testing.expect(!yieldsSanitizedHtml([]const u8));
    try testing.expect(!yieldsSanitizedHtml(?[]const u8));
    try testing.expect(!yieldsSanitizedHtml(void));
}

test "sanitize_html_is_the_only_public_producer_of_sanitized_html" {
    comptime var producers: []const []const u8 = &.{};
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const T = @TypeOf(@field(@This(), decl.name));
        if (@typeInfo(T) != .@"fn") continue;
        const ret = @typeInfo(T).@"fn".return_type orelse continue;
        if (comptime !yieldsSanitizedHtml(ret)) continue;
        producers = producers ++ [_][]const u8{decl.name};
    }

    // `cacheGet` relays a witness `sanitizeHtml` already minted; it cannot build one, and no other
    // public function may hand one out, whatever it wraps it in.
    try testing.expectEqual(@as(usize, 2), producers.len);
    for (producers) |name| {
        const expected = std.mem.eql(u8, name, "sanitizeHtml") or std.mem.eql(u8, name, "cacheGet");
        if (!expected) {
            std.debug.print("\nunexpected producer of SanitizedHtml: {s}\n", .{name});
            return error.UnexpectedSanitizedHtmlProducer;
        }
    }
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

test "unpack_splits_the_door_result_into_its_high_address_and_low_length" {
    try testing.expectEqual(Packed{ .addr = 0, .len = 0 }, unpack(0));
    try testing.expectEqual(Packed{ .addr = 0x1234, .len = 0x5678 }, unpack(0x0000_1234_0000_5678));
    // A zero address with a non-zero low word is still address zero: adopt reads it as the empty result.
    try testing.expectEqual(Packed{ .addr = 0, .len = 0x90AB }, unpack(0x0000_0000_0000_90AB));
    // Both halves at their 32-bit maximum must survive the split without borrowing each other's bits.
    try testing.expectEqual(Packed{ .addr = 0xFFFF_FFFF, .len = 0xFFFF_FFFF }, unpack(0xFFFF_FFFF_FFFF_FFFF));
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

/// A sanitize the door could not fulfil: `adopt` returns the failure sentinel when the dupe fails.
fn failedSanitize() SanitizedHtml {
    return .{ .bytes = failedBytes(), .witness_token = witness() };
}

test "is_failed_separates_the_dupe_failure_sentinel_from_a_legitimately_empty_result" {
    try testing.expect(isFailed(failedSanitize()));
    try testing.expect(!isFailed(.{ .bytes = "", .witness_token = witness() }));
    try testing.expect(!isFailed(.{ .bytes = "<p>x</p>", .witness_token = witness() }));
}

test "a_legitimately_empty_sanitize_is_cached_so_a_stripped_body_is_not_re_rendered_every_frame" {
    var r = RetireRing{ .allocator = testing.allocator };
    defer r.deinit();
    var c = Cache{ .allocator = testing.allocator, .ring = &r };
    defer c.deinit();

    const body = "<script>alert(1)</script>";
    // DOMPurify strips this to nothing; the empty result is real, not a failure, so it must cache.
    c.put(key(body), body, .{ .bytes = "", .witness_token = witness() });
    const hit = c.get(body);
    try testing.expect(hit != null);
    try testing.expectEqualStrings("", sink(hit.?));
}

test "a_failed_sanitize_is_not_cached_so_a_later_render_still_produces_the_real_html" {
    var r = RetireRing{ .allocator = testing.allocator };
    defer r.deinit();
    var c = Cache{ .allocator = testing.allocator, .ring = &r };
    defer c.deinit();

    const body = "a message body";
    c.put(key(body), body, failedSanitize());
    try testing.expect(c.get(body) == null);

    const real = try testing.allocator.dupe(u8, "<p>a message body</p>");
    defer testing.allocator.free(real);
    c.put(key(body), body, .{ .bytes = real, .witness_token = witness() });
    try testing.expectEqualStrings("<p>a message body</p>", sink(c.get(body).?));
}

test "a_cached_entry_survives_a_later_failed_sanitize_of_the_same_body" {
    var r = RetireRing{ .allocator = testing.allocator };
    defer r.deinit();
    var c = Cache{ .allocator = testing.allocator, .ring = &r };
    defer c.deinit();

    const body = "a message body";
    const real = try testing.allocator.dupe(u8, "<p>a message body</p>");
    defer testing.allocator.free(real);
    c.put(key(body), body, .{ .bytes = real, .witness_token = witness() });

    c.put(key(body), body, failedSanitize());
    try testing.expectEqualStrings("<p>a message body</p>", sink(c.get(body).?));
}

test "a_colliding_key_retires_the_displaced_bytes_instead_of_leaking_them" {
    var counting = Counting{ .child = testing.allocator };
    const gpa = counting.allocator();

    var r = RetireRing{ .allocator = gpa };
    defer r.deinit();
    var c = Cache{ .allocator = testing.allocator, .ring = &r };
    defer c.deinit();

    // One forced key for two distinct bodies: what a 64-bit Wyhash collision does to the cache.
    const collision: u64 = 0x5171_5EED_5171_5EED;
    const first = try gpa.dupe(u8, "<p>first</p>");
    c.put(collision, "first body", .{ .bytes = first, .witness_token = witness() });

    const second = try gpa.dupe(u8, "<p>second</p>");
    defer gpa.free(second);
    c.put(collision, "second body", .{ .bytes = second, .witness_token = witness() });

    // The displaced bytes may still sit in the vtree this render, so they retire, they do not vanish.
    try testing.expectEqual(@as(usize, 0), counting.frees);
    r.tick();
    r.tick();
    try testing.expectEqual(@as(usize, 1), counting.frees);

    const entry = c.map.get(collision).?;
    try testing.expectEqualStrings("second body", entry.src);
    try testing.expectEqualStrings("<p>second</p>", sink(entry.html));
}

test "a_cache_insert_that_cannot_allocate_retires_the_bytes_it_was_handed" {
    var counting = Counting{ .child = testing.allocator };
    const gpa = counting.allocator();

    var r = RetireRing{ .allocator = gpa };
    defer r.deinit();
    var c = Cache{ .allocator = testing.failing_allocator, .ring = &r };
    defer c.deinit();

    const body = "a message body";
    const orphan = try gpa.dupe(u8, "<p>a message body</p>");
    c.put(key(body), body, .{ .bytes = orphan, .witness_token = witness() });

    try testing.expect(c.get(body) == null);
    r.tick();
    r.tick();
    try testing.expectEqual(@as(usize, 1), counting.frees);
}
