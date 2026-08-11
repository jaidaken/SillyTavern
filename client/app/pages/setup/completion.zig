//! Extracts the token from one SSE data payload of a SillyTavern text-completion stream.
//!
//! For text-completion backends the server pipes the model's raw SSE through unchanged
//! (`src/endpoints/backends/text-completions.js` forwardFetchResponse), so a payload is either the
//! OpenAI-completions shape `{"choices":[{"text":...}]}`, the llama.cpp shape `{"content":...}`, or
//! the literal `[DONE]` terminator. The demo fixture sent a bare token; this replaces that read.

const std = @import("std");

pub const Event = union(enum) {
    /// A decoded token to append to the streaming message. Owned by `allocator`.
    token: []u8,
    /// Thinking text from a backend that reports it as its own field rather than inline think tags
    /// (llama.cpp `--reasoning-format deepseek`). Owned by `allocator`.
    reasoning: []u8,
    /// The stream's `[DONE]` terminator.
    done,
    /// A keepalive or a chunk that carried no token (empty text, comment line). Nothing to emit.
    empty,
};

/// A single SSE `data:` payload is one token's JSON, far below this. The cap bounds
/// `parseFromSlice` so one very long line cannot allocate a `Value` tree without limit; the stream
/// framer bounds an unterminated line, this bounds a terminated but oversized one. A payload this
/// large is not a real token.
const max_payload_len = 1 << 20;

/// `payload` is the bytes after `data: ` on one SSE line, already trimmed of the prefix and CR.
/// Caller owns `Event.token`.
pub fn parsePayload(allocator: std.mem.Allocator, payload: []const u8) !Event {
    const trimmed = std.mem.trim(u8, payload, " \t");
    if (trimmed.len == 0) return .empty;
    if (std.mem.eql(u8, trimmed, "[DONE]")) return .done;
    if (trimmed[0] != '{') return .empty;
    if (trimmed.len > max_payload_len) return .empty;

    // Malformed JSON is a keepalive-shaped payload, not a failure; a real OOM must propagate so the
    // stream retries the line rather than silently dropping the token.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .empty,
    };
    defer parsed.deinit();

    // Reasoning is read first: a deepseek-format frame carries its thinking under its own key, and
    // reading only the token shapes would drop it silently.
    if (reasoningText(parsed.value)) |think| {
        if (think.len > 0) return .{ .reasoning = try allocator.dupe(u8, think) };
    }

    const text = tokenText(parsed.value) orelse return .empty;
    if (text.len == 0) return .empty;
    return .{ .token = try allocator.dupe(u8, text) };
}

/// The thinking lives at `.choices[0].delta.reasoning_content` while streaming, at
/// `.choices[0].message.reasoning_content` in a whole-response body, or at the top level.
fn reasoningText(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const obj = v.object;

    if (obj.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first == .object) {
                inline for (.{ "delta", "message" }) |key| {
                    if (first.object.get(key)) |d| {
                        if (d == .object) {
                            if (d.object.get("reasoning_content")) |c| {
                                if (c == .string) return c.string;
                            }
                        }
                    }
                }
            }
        }
    }

    if (obj.get("reasoning_content")) |c| {
        if (c == .string) return c.string;
    }

    return null;
}

/// The token lives at `.choices[0].text` (OpenAI completions), `.choices[0].delta.content`
/// (OpenAI chat, which some text backends emit), or `.content` (llama.cpp `/completion`).
fn tokenText(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const obj = v.object;

    if (obj.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first == .object) {
                if (first.object.get("text")) |t| {
                    if (t == .string) return t.string;
                }
                if (first.object.get("delta")) |d| {
                    if (d == .object) {
                        if (d.object.get("content")) |c| {
                            if (c == .string) return c.string;
                        }
                    }
                }
            }
        }
    }

    if (obj.get("content")) |c| {
        if (c == .string) return c.string;
    }

    return null;
}

const testing = std.testing;

fn expectToken(payload: []const u8, want: []const u8) !void {
    const ev = try parsePayload(testing.allocator, payload);
    switch (ev) {
        .token => |tok| {
            defer testing.allocator.free(tok);
            try testing.expectEqualStrings(want, tok);
        },
        else => return error.ExpectedToken,
    }
}

fn expectReasoning(payload: []const u8, want: []const u8) !void {
    const ev = try parsePayload(testing.allocator, payload);
    switch (ev) {
        .reasoning => |think| {
            defer testing.allocator.free(think);
            try testing.expectEqualStrings(want, think);
        },
        else => return error.ExpectedReasoning,
    }
}

test "extracts a deepseek-format reasoning delta as reasoning, not body" {
    try expectReasoning(
        \\{"choices":[{"delta":{"reasoning_content":"weighing it up"},"index":0}]}
    , "weighing it up");
}

test "extracts reasoning from a whole-response message body" {
    try expectReasoning(
        \\{"choices":[{"message":{"reasoning_content":"pondering","content":"hi"}}]}
    , "pondering");
}

test "a delta carrying only content is still a body token" {
    try expectToken(
        \\{"choices":[{"delta":{"content":" world"},"index":0}]}
    , " world");
}

test "extracts an openai-completions text token" {
    try expectToken(
        \\{"id":"x","choices":[{"text":"hello","index":0,"finish_reason":null}]}
    , "hello");
}

test "extracts an openai-chat delta token" {
    try expectToken(
        \\{"choices":[{"delta":{"content":" world"},"index":0}]}
    , " world");
}

test "extracts a llamacpp content token" {
    try expectToken(
        \\{"content":"tok","stop":false}
    , "tok");
}

test "recognises the done terminator" {
    try testing.expectEqual(Event.done, try parsePayload(testing.allocator, "[DONE]"));
    try testing.expectEqual(Event.done, try parsePayload(testing.allocator, " [DONE] "));
}

test "a keepalive or empty text yields nothing to emit" {
    try testing.expectEqual(Event.empty, try parsePayload(testing.allocator, ""));
    try testing.expectEqual(Event.empty, try parsePayload(testing.allocator, ": keepalive"));
    try testing.expectEqual(Event.empty, try parsePayload(testing.allocator,
        \\{"choices":[{"text":"","finish_reason":"stop"}]}
    ));
}

test "malformed json is swallowed as empty, never a crash" {
    try testing.expectEqual(Event.empty, try parsePayload(testing.allocator, "{not json"));
    try testing.expectEqual(Event.empty, try parsePayload(testing.allocator, "{}"));
    try testing.expectEqual(Event.empty, try parsePayload(testing.allocator,
        \\{"choices":[]}
    ));
}

test "an oversized token payload is dropped rather than parsed" {
    const prefix = "{\"content\":\"";
    const suffix = "\"}";
    const buf = try testing.allocator.alloc(u8, prefix.len + max_payload_len + suffix.len);
    defer testing.allocator.free(buf);
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..][0..max_payload_len], 'x');
    @memcpy(buf[prefix.len + max_payload_len ..], suffix);

    // Without the cap this is a well-formed token and would parse; the cap drops it before the
    // Value tree is built.
    try testing.expectEqual(Event.empty, try parsePayload(testing.allocator, buf));
}

fn parseAndFree(allocator: std.mem.Allocator, payload: []const u8) !void {
    const ev = try parsePayload(allocator, payload);
    switch (ev) {
        .token => |tok| allocator.free(tok),
        else => {},
    }
}

test "parsePayload_cleans_up_on_every_allocation_failure" {
    const payload: []const u8 = "{\"content\":\"a token that gets duped\"}";
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{payload});
}

test "parsePayload_never_leaks_and_only_reports_done_for_the_sentinel" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var buf: [128]u8 = undefined;
    for (0..5000) |_| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        const ev = parsePayload(testing.allocator, buf[0..len]) catch continue;
        switch (ev) {
            .token => |tok| testing.allocator.free(tok),
            .reasoning => |think| testing.allocator.free(think),
            .done => try testing.expect(std.mem.eql(u8, std.mem.trim(u8, buf[0..len], " \t"), "[DONE]")),
            .empty => {},
        }
    }
}
