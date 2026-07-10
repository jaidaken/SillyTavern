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
const completion = @import("./completion.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;

const data_prefix = "data:";

/// One SSE `data:` line is one token payload, far below this. The cap bounds a peer that streams
/// bytes without ever sending `\n`, which would otherwise grow `line` until the wasm heap dies.
const max_line_len = 1 << 20;

pub const State = enum { idle, streaming, done };

pub const Error = error{StreamInProgress} || Allocator.Error;
pub const FeedError = error{LineTooLong} || Allocator.Error;

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
    /// Set by `emit` on `[DONE]`, acted on by `feed` once `drain` has stopped reading `line`.
    /// Sealing from inside `emit` would free the buffer `drain` is iterating.
    saw_done: bool = false,

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
        self.saw_done = false;

        try self.store.beginStream(name);
        self.state = .streaming;
    }

    /// Feeds raw bytes from the door. One call per animation frame, not per token.
    ///
    /// A decode that runs out of memory consumes nothing: the carry and `line` are put back as they
    /// were, so the same bytes may be fed again. A `drain` that runs out of memory keeps the lines
    /// it could not emit and never re-emits the ones it did.
    ///
    /// A `[DONE]` anywhere in the fed bytes seals the stream: `drain` stops at the sentinel and the
    /// bytes after it are discarded, so a backend that holds the socket open past `[DONE]` adds no
    /// tokens. A pending line that grows past `max_line_len` with no newline seals the message and
    /// returns `error.LineTooLong` rather than truncate the run-on bytes into a token.
    pub fn feed(self: *Stream, bytes: []const u8) FeedError!void {
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

        if (self.saw_done) {
            self.end();
            return;
        }

        // The residual is the current unterminated line; drain has already consumed every complete
        // one. Past the cap the peer is not framing, so seal rather than keep growing `line`.
        if (self.line.items.len > max_line_len) {
            self.seal();
            return error.LineTooLong;
        }
    }

    /// Ends the stream and seals the message. Always reaches `.done`, even out of memory: losing a
    /// token beats stranding the message in `.streaming` forever.
    ///
    /// Every line still held is emitted, not just the first: an allocation failure that costs one
    /// token must not cost the tokens received after it.
    pub fn end(self: *Stream) void {
        if (self.state != .streaming) return;

        // A `[DONE]` already seen means every remaining byte is post-sentinel and must not become a
        // token; seal without emitting.
        if (self.saw_done) {
            self.seal();
            return;
        }

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
        self.seal();
    }

    /// Discards any pending line and reaches `.done` without emitting it. Used at the `[DONE]`
    /// sentinel and when a line exceeds `max_line_len`, where the buffered bytes must not become a
    /// token.
    fn seal(self: *Stream) void {
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
            // Stop at the sentinel: lines after `[DONE]` in the same feed must not be emitted.
            if (self.saw_done) break;
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

        // parsePayload trims surrounding whitespace, decodes the backend's JSON token shapes, and
        // recognises [DONE]/keepalives. Its only error is OOM from duping the token.
        switch (try completion.parsePayload(self.allocator, line[data_prefix.len..])) {
            .token => |tok| {
                defer self.allocator.free(tok);
                try self.store.appendTail(tok);
                self.tokens += 1;
            },
            // Only flagged: `drain` is iterating `line`, which `end` frees.
            .done => self.saw_done = true,
            .empty => {},
        }
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

/// One llama.cpp SSE data line carrying `tok`, the shape a real backend sends. The token extractor
/// lives in completion.zig; these tests exercise the framing around it, so they use a real payload.
inline fn dl(comptime tok: []const u8) []const u8 {
    return "data: {\"content\":\"" ++ tok ++ "\"}\n";
}

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
    try f.stream.feed(dl("alpha"));
    try testing.expectError(error.StreamInProgress, f.open(testing.allocator, "Second"));

    try testing.expectEqual(@as(usize, 1), f.store.slice().len);
    try testing.expectEqualStrings("alpha", f.body(0));
}

test "two_sequential_streams_keep_separate_bodies" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "First");
    try f.stream.feed(dl("aaa"));
    f.stream.end();

    try f.open(testing.allocator, "Second");
    try f.stream.feed(dl("bbb"));
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
    // The last line carries a token with no trailing newline to close it.
    try f.stream.feed(dl("one") ++ "data: {\"content\":\"two\"}");
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
    try f.stream.feed("ta: {\"content\":\"hel");
    try f.stream.feed("lo\"}\n");

    try testing.expectEqualStrings("hello", f.body(0));
    try testing.expectEqual(@as(usize, 1), f.stream.tokens);
}

test "stream_reassembles_a_codepoint_split_across_chunks_inside_a_token" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    const emoji = "\u{1F600}";
    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed("data: {\"content\":\"" ++ emoji[0..2]);
    try f.stream.feed(emoji[2..4] ++ "\"}\n");
    f.stream.end();

    try testing.expectEqualStrings(emoji, f.body(0));
}

test "stream_emits_no_token_for_comment_or_event_lines" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed(": comment\nevent: ping\n" ++ dl("real") ++ "\n");
    f.stream.end();

    try testing.expectEqualStrings("real", f.body(0));
    try testing.expectEqual(@as(usize, 1), f.stream.tokens);
}

test "stream_seals_on_the_done_sentinel_with_no_external_end" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed(dl("real") ++ "data: [DONE]\n\n");

    // A backend that holds the socket open after [DONE] must not strand the message in .streaming.
    try testing.expectEqual(State.done, f.stream.state);
    try testing.expectEqual(@as(?usize, null), f.store.stream_index);
    try testing.expectEqualStrings("real", f.body(0));
    try testing.expectEqual(@as(usize, 1), f.stream.tokens);

    try f.stream.feed(dl("after"));
    try testing.expectEqualStrings("real", f.body(0));
    try testing.expectEqual(@as(usize, 1), f.stream.tokens);
}

test "a_single_feed_ignores_tokens_after_the_done_sentinel" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    // The whole frame coalesces into one feed, so the sentinel and the trailing token arrive
    // together; only the token before [DONE] may survive.
    try f.stream.feed(dl("tok") ++ "data: [DONE]\n" ++ dl("after"));

    try testing.expectEqual(State.done, f.stream.state);
    try testing.expectEqual(@as(?usize, null), f.store.stream_index);
    try testing.expectEqualStrings("tok", f.body(0));
    try testing.expectEqual(@as(usize, 1), f.stream.tokens);
}

test "a_pending_line_past_the_cap_seals_without_a_bogus_token" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");

    const big = try testing.allocator.alloc(u8, max_line_len + 16);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    @memcpy(big[0..data_prefix.len], data_prefix);

    // No newline ever arrives, so a peer could grow `line` without bound. The cap seals the stream
    // and surfaces the error instead of turning the run-on bytes into a token.
    try testing.expectError(error.LineTooLong, f.stream.feed(big));

    try testing.expectEqual(State.done, f.stream.state);
    try testing.expectEqual(@as(?usize, null), f.store.stream_index);
    try testing.expectEqual(@as(usize, 0), f.stream.tokens);
    try testing.expectEqualStrings("", f.body(0));
}

test "stream_seals_on_a_done_sentinel_split_across_chunks" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed(dl("real") ++ "data: [DO");
    try testing.expectEqual(State.streaming, f.stream.state);
    try f.stream.feed("NE]\n");

    try testing.expectEqual(State.done, f.stream.state);
    try testing.expectEqualStrings("real", f.body(0));
}

test "stream_seals_on_a_done_sentinel_that_has_no_trailing_newline" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed(dl("real") ++ "data: [DONE]");
    // No newline closes the sentinel, so only end() sees it. The seal must still happen once.
    try testing.expectEqual(State.streaming, f.stream.state);
    f.stream.end();

    try testing.expectEqual(State.done, f.stream.state);
    try testing.expectEqualStrings("real", f.body(0));
    try testing.expectEqual(@as(usize, 1), f.stream.tokens);
}

test "stream_strips_a_trailing_carriage_return_before_extraction" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.open(testing.allocator, "Seraphina");
    try f.stream.feed("data: {\"content\":\"hi\"}\r\n");
    f.stream.end();

    try testing.expectEqualStrings("hi", f.body(0));
}

test "feed_before_begin_is_silent" {
    var f: Fixture = undefined;
    f.init(testing.allocator);
    defer f.deinit();

    try f.stream.feed(dl("ignored"));
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
        var buf: [48]u8 = undefined;
        try f.stream.feed(try std.fmt.bufPrint(&buf, "data: {{\"content\":\"tok{d}\"}}\n", .{i}));
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

    // A trailing newline seals every token during feed, so this exercises only the feed path, which
    // propagates OOM cleanly (checkAllAllocationFailures requires propagation). end()'s deliberate
    // drop-not-strand behaviour is covered by the sweep test below. [DONE] comes last: it seals the
    // stream, and the tokens behind it would never be read.
    const wire_bytes = "data: {\"content\":\"al\u{4E16}pha\"}\ndata: {\"content\":\"beta\"}\ndata: [DONE]\n";
    var at: usize = 0;
    while (at < wire_bytes.len) {
        const take = @min(wire_bytes.len - at, chunk_size);
        try f.stream.feed(wire_bytes[at..][0..take]);
        at += take;
    }

    // Reaching here means no injected failure fired, so every token streamed into the sealed body.
    try testing.expectEqual(State.done, f.stream.state);
    try testing.expectEqualStrings("al\u{4E16}phabeta", f.body(0));
}

test "stream_releases_everything_on_any_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, feedScenario, .{@as(usize, 3)});
}

fn failingAllocator() testing.FailingAllocator {
    return testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
}

/// The sealed body must be the in-order concatenation of some subset of `tokens`. Each token is
/// all-or-nothing: parsePayload dupes it, then store.appendTail grows the tail, both failing
/// atomically, so a token an allocation failure dropped is absent, never partial or duplicated, and
/// nothing else appears. The body also never carries a newline.
fn expectInOrderSubset(body: []const u8, comptime tokens: []const []const u8) !void {
    try testing.expect(std.mem.indexOfScalar(u8, body, '\n') == null);
    var i: usize = 0;
    inline for (tokens) |t| {
        if (std.mem.startsWith(u8, body[i..], t)) i += t.len;
    }
    try testing.expectEqual(body.len, i);
}

// Feeds a tail-growing token, then a big-plus-small pair whose last line has no terminating newline,
// so a mid-stream drain and an end-time drain both run. Sweeps an injected allocation failure across
// every point of that scenario; wherever it lands, the invariant must hold and the stream must seal.
test "no allocation failure double-emits, partial-emits, or strands the stream" {
    for (0..64) |k| {
        var failing = failingAllocator();
        const gpa = failing.allocator();

        var f: Fixture = undefined;
        f.init(gpa);
        defer f.deinit();
        f.open(gpa, "Seraphina") catch continue;

        failing.fail_index = failing.alloc_index + k;
        f.stream.feed(dl("a" ** 64)) catch {};
        f.stream.feed(dl("b" ** 4096) ++ "data: {\"content\":\"c\"}") catch {};
        failing.fail_index = std.math.maxInt(usize);
        f.stream.end();

        try testing.expectEqual(State.done, f.stream.state);
        try expectInOrderSubset(f.body(0), &.{ "a" ** 64, "b" ** 4096, "c" });
    }
}

test "a_feed_that_runs_out_of_memory_consumes_none_of_its_bytes" {
    const cut_codepoint = "data: {\"content\":\"ab\xe4\xb8";
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

        try f.stream.feed("\x96\"}\n");
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
    try f.stream.feed(dl("one") ++ dl("two"));
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
