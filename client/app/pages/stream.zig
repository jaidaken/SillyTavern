//! The streaming lifecycle: Idle -> Streaming -> Done.
//!
//! Owns everything between the door's raw SSE bytes and the store's tail: UTF-8 decoding across
//! chunk boundaries, SSE line framing, and the transfer of the finished buffer to the message.
//!
//! Framing lives here rather than in the glue because a `data:` line can be cut anywhere, including
//! through a multibyte codepoint. One carry (the decoder's) covers the split codepoint, another
//! (`line`) covers the split line, and the final unterminated line is still delivered at `end`.
//!
//! Reentry is refused, not absorbed: a second `begin` while streaming would otherwise retarget the
//! tail onto a new message and alias the first message's body.

const std = @import("std");

const store_mod = @import("./store.zig");
const utf8 = @import("./utf8.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;

const data_prefix = "data:";
const done_sentinel = "[DONE]";

pub const State = enum { idle, streaming, done };

pub const Error = error{StreamInProgress} || Allocator.Error;

pub const Stream = struct {
    allocator: Allocator,
    store: *Store,
    state: State = .idle,
    decoder: utf8.Decoder = .{},
    /// The bytes received and not yet emitted. Free of `\n` once `drain` returns, so `end` never
    /// sees one; a `drain` stopped by an allocation failure leaves the lines it could not emit here
    /// for the next `feed` or `end` to retry.
    line: std.ArrayList(u8) = .empty,
    tokens: usize = 0,

    pub fn deinit(self: *Stream) void {
        self.line.deinit(self.allocator);
        self.* = undefined;
    }

    /// Takes ownership of `name` on success. On failure the caller still owns it, and the counters
    /// are already those of the refused stream rather than the finished one.
    pub fn begin(self: *Stream, name: []u8) Error!void {
        if (self.state == .streaming) return error.StreamInProgress;

        self.decoder = .{};
        self.line.clearRetainingCapacity();
        self.tokens = 0;

        try self.store.beginStream(name);
        self.state = .streaming;
    }

    /// Feeds raw bytes from the door. One call per animation frame, not per token.
    ///
    /// A decode that runs out of memory consumes nothing: the carry and `line` are put back as they
    /// were, so the same bytes may be fed again. A `drain` that runs out of memory keeps the lines
    /// it could not emit and never re-emits the ones it did.
    pub fn feed(self: *Stream, bytes: []const u8) Allocator.Error!void {
        if (self.state != .streaming) return;

        {
            const carry = self.decoder;
            const mark = self.line.items.len;
            errdefer {
                self.decoder = carry;
                self.line.shrinkRetainingCapacity(mark);
            }
            try self.decoder.feedInto(self.allocator, &self.line, bytes);
        }

        try self.drain();
    }

    /// Ends the stream and seals the message. Always reaches `.done`, even out of memory: losing a
    /// token beats stranding the message in `.streaming` forever.
    ///
    /// Every line still held is emitted, not just the first: an allocation failure that costs one
    /// token must not cost the tokens received after it.
    pub fn end(self: *Stream) void {
        if (self.state != .streaming) return;

        if (self.decoder.flush(self.allocator)) |tail| {
            defer self.allocator.free(tail);
            self.line.appendSlice(self.allocator, tail) catch {};
        } else |_| {}

        // A failed drain left complete lines here, so each is emitted on its own: one failing emit
        // must not discard the tokens behind it, which nothing can resend.
        const rest = self.line.items;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rest, start, '\n')) |nl| {
            self.emit(rest[start..nl]) catch {};
            start = nl + 1;
        }
        // The last line carries a token even with no trailing newline to close it.
        self.emit(rest[start..]) catch {};
        self.line.clearAndFree(self.allocator);
        self.store.endStream();
        self.state = .done;
    }

    fn drain(self: *Stream) Allocator.Error!void {
        var start: usize = 0;
        // Runs on the error path too: a line that was emitted must never be emitted again.
        defer self.consume(start);

        while (std.mem.indexOfScalarPos(u8, self.line.items, start, '\n')) |nl| {
            try self.emit(self.line.items[start..nl]);
            start = nl + 1;
        }
    }

    /// Drops the first `start` bytes of `line`, which `drain` has emitted and will not revisit.
    fn consume(self: *Stream, start: usize) void {
        if (start == 0) return;

        const rest = self.line.items.len - start;
        std.mem.copyForwards(u8, self.line.items[0..rest], self.line.items[start..]);
        self.line.shrinkRetainingCapacity(rest);
    }

    fn emit(self: *Stream, raw_line: []const u8) Allocator.Error!void {
        std.debug.assert(std.mem.indexOfScalar(u8, raw_line, '\n') == null);

        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (!std.mem.startsWith(u8, line, data_prefix)) return;

        var payload = line[data_prefix.len..];
        if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
        if (payload.len == 0 or std.mem.eql(u8, payload, done_sentinel)) return;

        try self.store.appendTail(payload);
        self.tokens += 1;
    }
};

const testing = std.testing;

const Fixture = struct {
    store: Store,
    stream: Stream,

    /// In place: `stream` holds `&self.store`, so the fixture must never be copied after this.
    fn init(self: *Fixture, gpa: Allocator) void {
        self.store = Store.init(gpa);
        self.stream = .{ .allocator = gpa, .store = &self.store };
    }

    fn deinit(self: *Fixture) void {
        self.stream.deinit();
        self.store.deinit();
    }

    fn open(self: *Fixture, gpa: Allocator, name: []const u8) !void {
        const owned = try gpa.dupe(u8, name);
        self.stream.begin(owned) catch |err| {
            gpa.free(owned);
            return err;
        };
    }

    fn body(self: *const Fixture, index: usize) []const u8 {
        return self.store.slice()[index].body;
    }
};

test "stream_moves_idle_to_streaming_to_done" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try testing.expectEqual(State.idle, f.stream.state);
    try f.open(testing.allocator, "Seraphina");
    try testing.expectEqual(State.streaming, f.stream.state);
    f.stream.end();
    try testing.expectEqual(State.done, f.stream.state);
}

test "stream_refuses_a_second_begin_while_streaming" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "First");
    try f.stream.feed("data: alpha\n");
    try testing.expectError(error.StreamInProgress, f.open(testing.allocator, "Second"));

    try testing.expectEqual(@as(usize, 1), f.store.slice().len);
    try testing.expectEqualStrings("alpha", f.body(0));
}

test "two_sequential_streams_keep_separate_bodies" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "First");
    try f.stream.feed("data: aaa\n");
    f.stream.end();

    try f.open(testing.allocator, "Second");
    try f.stream.feed("data: bbb\n");
    f.stream.end();

    try testing.expectEqual(@as(usize, 2), f.store.slice().len);
    try testing.expectEqualStrings("aaa", f.body(0));
    try testing.expectEqualStrings("bbb", f.body(1));
    try testing.expect(f.body(0).ptr != f.body(1).ptr);
}

test "stream_delivers_a_final_token_that_has_no_trailing_newline" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed("data: one\ndata: two");
    f.stream.end();

    try testing.expectEqualStrings("onetwo", f.body(0));
    try testing.expectEqual(@as(usize, 2), f.stream.tokens);
}

test "stream_reassembles_a_data_line_split_across_chunks" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed("da");
    try f.stream.feed("ta: hel");
    try f.stream.feed("lo\n");

    try testing.expectEqualStrings("hello", f.body(0));
    try testing.expectEqual(@as(usize, 1), f.stream.tokens);
}

test "stream_reassembles_a_codepoint_split_across_chunks_inside_a_token" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    const emoji = "\u{1F600}";
    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed("data: " ++ emoji[0..2]);
    try f.stream.feed(emoji[2..4] ++ "\n");
    f.stream.end();

    try testing.expectEqualStrings(emoji, f.body(0));
}

test "stream_skips_the_done_sentinel_and_non_data_lines" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed(": comment\nevent: ping\ndata: real\ndata: [DONE]\n\n");
    f.stream.end();

    try testing.expectEqualStrings("real", f.body(0));
    try testing.expectEqual(@as(usize, 1), f.stream.tokens);
}

test "stream_strips_one_leading_space_and_a_trailing_carriage_return" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed("data:  two spaces\r\n");
    f.stream.end();

    try testing.expectEqualStrings(" two spaces", f.body(0));
}

test "feed_before_begin_is_silent" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.stream.feed("data: ignored\n");
    f.stream.end();

    try testing.expectEqual(@as(usize, 0), f.store.slice().len);
    try testing.expectEqual(State.idle, f.stream.state);
}

test "stream_appends_many_tokens_in_order" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    for (0..200) |i| {
        var buf: [24]u8 = undefined;
        try f.stream.feed(try std.fmt.bufPrint(&buf, "data: tok{d}\n", .{i}));
    }
    f.stream.end();

    try testing.expectEqual(@as(usize, 200), f.stream.tokens);
    try testing.expect(std.mem.startsWith(u8, f.body(0), "tok0tok1"));
    try testing.expect(std.mem.endsWith(u8, f.body(0), "tok199"));
}

fn feedScenario(gpa: Allocator, chunk_size: usize) !void {
    var f: Fixture = undefined;
    f.init(gpa);
    defer f.deinit();

    try f.open(gpa, "Seraphina");

    const wire_bytes = "data: al\u{4E16}pha\ndata: [DONE]\ndata: beta";
    var at: usize = 0;
    while (at < wire_bytes.len) {
        const take = @min(wire_bytes.len - at, chunk_size);
        try f.stream.feed(wire_bytes[at..][0..take]);
        at += take;
    }
    f.stream.end();

    try testing.expectEqualStrings("al\u{4E16}phabeta", f.body(0));
}

test "stream_releases_everything_on_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, feedScenario, .{@as(usize, 3)});
}

// The second token dwarfs the spare capacity the first one leaves in the store's tail. Emitting it
// therefore always allocates, which is the failure the sweeps below inject between two emits.
const token_a = "a" ** 48;
const token_b = "b" ** 4096;
const token_c = "c" ** 4;
const two_lines = "data: " ++ token_a ++ "\ndata: " ++ token_b ++ "\n";

fn failingAllocator() testing.FailingAllocator {
    return testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
}

/// Asserts the sealed body holds each token it contains exactly once, in wire order, and no `\n`.
fn expectNoTokenEmittedTwice(f: *Fixture) !void {
    const body = f.body(0);
    try testing.expect(std.mem.indexOfScalar(u8, body, '\n') == null);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);

    var count: usize = 0;
    inline for (.{ token_a, token_b, token_c }) |token| {
        if (std.mem.indexOfScalar(u8, body, token[0]) != null) {
            try expected.appendSlice(testing.allocator, token);
            count += 1;
        }
    }

    try testing.expectEqualStrings(expected.items, body);
    try testing.expectEqual(count, f.stream.tokens);
}

// The state a drain stopped by an allocation failure leaves in `line`: complete lines, unemitted.
// The first token cannot fit without growing the tail; the one behind it fits the spare capacity.
const undrained_lines = "data: " ++ "b" ** 4096 ++ "\ndata: z\n";

test "end_emits_the_lines_behind_one_whose_emit_ran_out_of_memory" {
    var failing = failingAllocator();
    const gpa = failing.allocator();

    var f: Fixture = undefined;
    f.init(gpa);
    defer f.deinit();
    try f.open(gpa, "Seraphina");

    // A first small token leaves the tail with spare capacity a later one-byte token can use.
    try f.stream.feed("data: a\n");
    try testing.expect(f.store.tail.capacity > f.store.tail.items.len);

    try f.stream.line.appendSlice(gpa, undrained_lines);

    failing.fail_index = failing.alloc_index;
    f.stream.end();
    failing.fail_index = std.math.maxInt(usize);

    try testing.expect(failing.has_induced_failure);
    try testing.expectEqualStrings("az", f.body(0));
    try testing.expectEqual(@as(usize, 2), f.stream.tokens);
    try testing.expectEqual(State.done, f.stream.state);
}

test "a_failed_emit_never_lets_a_later_feed_emit_the_same_line_twice" {
    var saw_emit_failure = false;

    for (0..16) |k| {
        var failing = failingAllocator();
        const gpa = failing.allocator();

        var f: Fixture = undefined;
        f.init(gpa);
        defer f.deinit();
        try f.open(gpa, "Seraphina");

        failing.fail_index = failing.alloc_index + k;
        const failed = if (f.stream.feed(two_lines)) |_| false else |_| true;
        const emitted_before_failure = f.body(0).len > 0;
        failing.fail_index = std.math.maxInt(usize);

        try f.stream.feed("data: " ++ token_c ++ "\n");
        f.stream.end();
        try expectNoTokenEmittedTwice(&f);

        if (failed and emitted_before_failure) {
            saw_emit_failure = true;
            try testing.expectEqual(@as(usize, 3), f.stream.tokens);
        }
    }

    try testing.expect(saw_emit_failure);
}

test "end_seals_a_newline_free_body_when_a_feed_left_lines_undrained" {
    var saw_undrained_line = false;

    for (0..16) |k| {
        var failing = failingAllocator();
        const gpa = failing.allocator();

        var f: Fixture = undefined;
        f.init(gpa);
        defer f.deinit();
        try f.open(gpa, "Seraphina");

        failing.fail_index = failing.alloc_index + k;
        const failed = if (f.stream.feed(two_lines)) |_| false else |_| true;
        const undrained = std.mem.indexOfScalar(u8, f.stream.line.items, '\n') != null;
        failing.fail_index = std.math.maxInt(usize);
        if (failed and undrained) saw_undrained_line = true;

        f.stream.end();
        try expectNoTokenEmittedTwice(&f);
        try testing.expectEqual(State.done, f.stream.state);
    }

    try testing.expect(saw_undrained_line);
}

test "a_feed_that_runs_out_of_memory_consumes_none_of_its_bytes" {
    const cut_codepoint = "data: ab\xe4\xb8";
    var saw_decode_failure = false;

    for (0..6) |k| {
        var failing = failingAllocator();
        const gpa = failing.allocator();

        var f: Fixture = undefined;
        f.init(gpa);
        defer f.deinit();
        try f.open(gpa, "Seraphina");

        failing.fail_index = failing.alloc_index + k;
        const failed = if (f.stream.feed(cut_codepoint)) |_| false else |_| true;
        failing.fail_index = std.math.maxInt(usize);

        if (failed) {
            saw_decode_failure = true;
            try testing.expectEqual(@as(usize, 0), f.stream.line.items.len);
            try testing.expectEqual(@as(usize, 0), f.stream.decoder.partial_len);
            try f.stream.feed(cut_codepoint);
        }

        try f.stream.feed("\x96\n");
        f.stream.end();

        try testing.expectEqualStrings("ab\u{4E16}", f.body(0));
        try testing.expectEqual(@as(usize, 1), f.stream.tokens);
    }

    try testing.expect(saw_decode_failure);
}

test "begin_resets_the_token_count_when_the_store_refuses_the_new_stream" {
    var failing = failingAllocator();
    const gpa = failing.allocator();

    var f: Fixture = undefined;
    f.init(gpa);
    defer f.deinit();

    try f.open(gpa, "First");
    try f.stream.feed("data: one\ndata: two\n");
    f.stream.end();
    try testing.expectEqual(@as(usize, 2), f.stream.tokens);

    // beginStream allocates only when the message list grows, so bring it to capacity first.
    while (f.store.messages.items.len < f.store.messages.capacity) try f.store.appendCopy("You", "hi");

    const name = try gpa.dupe(u8, "Second");
    defer gpa.free(name);
    const sealed = f.store.slice().len;

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, f.stream.begin(name));
    failing.fail_index = std.math.maxInt(usize);

    try testing.expectEqual(@as(usize, 0), f.stream.tokens);
    try testing.expectEqual(State.done, f.stream.state);
    try testing.expectEqual(sealed, f.store.slice().len);
}
