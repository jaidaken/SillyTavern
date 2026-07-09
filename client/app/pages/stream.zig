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
    /// The trailing partial SSE line, always free of `\n`.
    line: std.ArrayList(u8) = .empty,
    tokens: usize = 0,

    pub fn deinit(self: *Stream) void {
        self.line.deinit(self.allocator);
        self.* = undefined;
    }

    /// Takes ownership of `name` on success. On failure the caller still owns it.
    pub fn begin(self: *Stream, name: []u8) Error!void {
        if (self.state == .streaming) return error.StreamInProgress;
        try self.store.beginStream(name);
        self.state = .streaming;
        self.decoder = .{};
        self.line.clearRetainingCapacity();
        self.tokens = 0;
    }

    /// Feeds raw bytes from the door. One call per animation frame, not per token.
    pub fn feed(self: *Stream, bytes: []const u8) Allocator.Error!void {
        if (self.state != .streaming) return;

        const text = try self.decoder.feed(self.allocator, bytes);
        defer self.allocator.free(text);
        try self.line.appendSlice(self.allocator, text);
        try self.drain();
    }

    /// Ends the stream and seals the message. Always reaches `.done`, even out of memory: losing
    /// the last token beats stranding the message in `.streaming` forever.
    pub fn end(self: *Stream) void {
        if (self.state != .streaming) return;

        if (self.decoder.flush(self.allocator)) |tail| {
            defer self.allocator.free(tail);
            self.line.appendSlice(self.allocator, tail) catch {};
        } else |_| {}

        // The last line carries a token even with no trailing newline to close it.
        self.emit(self.line.items) catch {};
        self.line.clearAndFree(self.allocator);
        self.store.endStream();
        self.state = .done;
    }

    fn drain(self: *Stream) Allocator.Error!void {
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.line.items, start, '\n')) |nl| {
            try self.emit(self.line.items[start..nl]);
            start = nl + 1;
        }
        if (start == 0) return;

        const rest = self.line.items.len - start;
        std.mem.copyForwards(u8, self.line.items[0..rest], self.line.items[start..]);
        self.line.shrinkRetainingCapacity(rest);
    }

    fn emit(self: *Stream, raw_line: []const u8) Allocator.Error!void {
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
