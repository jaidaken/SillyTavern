//! The author's note: a per-chat block of text injected into the prompt, used to steer a scene
//! without editing the card ("keep replies short", "it is raining").
//!
//! STORAGE IS THE CLASSIC CLIENT'S, unchanged (authors-note.js:29): the note lives in the chat
//! file's own header under `chat_metadata`, keyed `note_prompt` / `note_interval` / `note_depth` /
//! `note_position` / `note_role`. Per chat, not per character and not global, so the same card in two
//! chats carries two notes. Invariant 1 holds: these are the keys stock already writes, so a note set
//! here is read by stock and the other way round, and the file stays stock jsonl.
//!
//! THREE PLACES IT CAN LAND (`Position`, the classic `extension_prompt_types`):
//!   before_prompt (2) -> the `{{anchorBefore}}` slot at the top of the story string
//!   in_prompt (0)     -> the `{{anchorAfter}}` slot at the bottom of the story string
//!   in_chat (1)       -> injected INTO the history at `depth` turns from the newest
//! The first two ride the Ctx anchors renderStoryString already resolves; the third is a real
//! history insertion, which is why `injectionIndex` lives here.
//!
//! INTERVAL is the classic client's periodic mode: the note is inserted only every Nth message
//! (authors-note.js:346). 1 inserts always, 0 or less disables it entirely.
//!
//! zx-free, so `zig build test` proves the parse and the placement natively (ZX5);
//! authors_note_state.zig owns the fetch, the save and the DOM.

const std = @import("std");

const templates = @import("./templates.zig");

const Allocator = std.mem.Allocator;

pub const Position = templates.Position;

/// Whose turn the note speaks as when it lands in the chat. Matches the classic client's role ints
/// (authors-note.js validRoles): system 0, user 1, assistant 2.
pub const Role = enum(i64) {
    system = 0,
    user = 1,
    assistant = 2,

    pub fn fromInt(v: i64) ?Role {
        return switch (v) {
            0 => .system,
            1 => .user,
            2 => .assistant,
            else => null,
        };
    }

    pub fn toTemplateRole(self: Role) templates.Role {
        return switch (self) {
            .system => .system,
            .user => .user,
            .assistant => .assistant,
        };
    }
};

pub const default_interval: i64 = 1;
pub const default_depth: i64 = 4;
pub const default_position: Position = .in_chat;
pub const default_role: Role = .system;

/// A chat's note. `prompt` is BORROWED from whatever parsed the metadata; parseOwned dupes it.
pub const Note = struct {
    prompt: []const u8 = "",
    interval: i64 = default_interval,
    depth: i64 = default_depth,
    position: Position = default_position,
    role: Role = default_role,

    /// Whether this note contributes anything to a prompt at all. An empty note is not an error, it
    /// is the normal state of most chats, so every injection path checks this first.
    pub fn active(self: Note) bool {
        return std.mem.trim(u8, self.prompt, " \t\r\n").len > 0 and self.interval > 0;
    }
};

/// Reads a note out of a parsed `chat_metadata` object. Every field degrades to its default
/// independently: the header comes off disk and is not coerced by the server, so a note whose depth
/// is a string must cost the DEPTH, never the note.
pub fn parse(metadata: std.json.Value) Note {
    var note = Note{};
    const obj = switch (metadata) {
        .object => |o| o,
        else => return note,
    };
    if (obj.get("note_prompt")) |v| {
        if (v == .string) note.prompt = v.string;
    }
    if (numField(obj, "note_interval")) |v| note.interval = v;
    if (numField(obj, "note_depth")) |v| note.depth = @max(0, v);
    if (numField(obj, "note_position")) |v| {
        if (Position.fromInt(v)) |p| note.position = p;
    }
    if (numField(obj, "note_role")) |v| {
        if (Role.fromInt(v)) |r| note.role = r;
    }
    return note;
}

/// `parse` with the prompt duped, for a caller that outlives the json arena the metadata came from.
pub fn parseOwned(alloc: Allocator, metadata: std.json.Value) Allocator.Error!Note {
    var note = parse(metadata);
    note.prompt = try alloc.dupe(u8, note.prompt);
    return note;
}

pub fn freeOwned(alloc: Allocator, note: Note) void {
    alloc.free(note.prompt);
}

/// A number field, tolerating the string spelling (the classic client's inputs have written both a
/// number and a numeric string into this metadata over the years).
fn numField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isNan(f)) null else @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch null,
        else => null,
    };
}

/// Writes the note back into the metadata object, in place, preserving every other key the header
/// carries. `chat_metadata` also holds things this client does not model yet (integrity, tainted,
/// timedWorldInfo), and dropping them would corrupt a chat stock still reads.
pub fn merge(a: Allocator, metadata: *std.json.ObjectMap, note: Note) Allocator.Error!void {
    try metadata.put(a, "note_prompt", .{ .string = try a.dupe(u8, note.prompt) });
    try metadata.put(a, "note_interval", .{ .integer = note.interval });
    try metadata.put(a, "note_depth", .{ .integer = note.depth });
    try metadata.put(a, "note_position", .{ .integer = @intFromEnum(note.position) });
    try metadata.put(a, "note_role", .{ .integer = @intFromEnum(note.role) });
}

/// Whether the note fires for a history of `message_count` messages. The classic client's rule
/// (authors-note.js:346): interval 1 always inserts, interval <= 0 never does, and otherwise the
/// note appears when the count divides evenly into the interval.
pub fn shouldInject(note: Note, message_count: usize) bool {
    return note.active() and intervalFires(note, message_count);
}

/// Whether the note's INTERVAL fires this generation, independent of the note text being empty
/// (stock shouldWIAddPrompt, authors-note.js:346). shouldInject adds the emptiness check on top; the
/// persona TOP_AN / BOTTOM_AN join reads this directly, since it fires even for an empty note.
pub fn intervalFires(note: Note, message_count: usize) bool {
    if (note.interval == 1) return true;
    if (note.interval <= 0) return false;
    if (message_count == 0) return false;
    const interval: usize = @intCast(note.interval);
    return message_count % interval == 0;
}

/// Where an `in_chat` note sits in a history slice: `depth` turns back from the end, clamped into
/// the slice. Depth 0 puts it after the newest message (right before the model answers), depth 1
/// before the newest, and a depth past the start pins it at the head rather than wrapping.
///
/// Returns null when the note does not apply to this history at all, so the caller has one check.
pub fn injectionIndex(note: Note, history_len: usize) ?usize {
    if (note.position != .in_chat) return null;
    if (!shouldInject(note, history_len)) return null;
    const depth: usize = @intCast(@max(0, note.depth));
    return history_len -| depth;
}

const testing = std.testing;

fn parseStr(s: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
}

test "parse reads the classic metadata keys" {
    const p = try parseStr(
        \\{"note_prompt":"It is raining.","note_interval":3,"note_depth":2,"note_position":0,"note_role":1}
    );
    defer p.deinit();
    const note = parse(p.value);
    try testing.expectEqualStrings("It is raining.", note.prompt);
    try testing.expectEqual(@as(i64, 3), note.interval);
    try testing.expectEqual(@as(i64, 2), note.depth);
    try testing.expectEqual(Position.in_prompt, note.position);
    try testing.expectEqual(Role.user, note.role);
}

test "parse defaults an absent, empty, or non-object metadata" {
    const empty = try parseStr("{}");
    defer empty.deinit();
    const note = parse(empty.value);
    try testing.expectEqualStrings("", note.prompt);
    try testing.expectEqual(default_interval, note.interval);
    try testing.expectEqual(default_depth, note.depth);
    try testing.expectEqual(default_position, note.position);
    try testing.expectEqual(default_role, note.role);
    try testing.expect(!note.active());

    const arr = try parseStr("[1,2]");
    defer arr.deinit();
    try testing.expect(!parse(arr.value).active());
}

test "parse costs only the bad field when the metadata is hostile" {
    // The header is read off disk uncoerced, so every field degrades on its own.
    const p = try parseStr(
        \\{"note_prompt":"keep it","note_interval":"2","note_depth":null,"note_position":99,"note_role":["nope"]}
    );
    defer p.deinit();
    const note = parse(p.value);
    try testing.expectEqualStrings("keep it", note.prompt);
    try testing.expectEqual(@as(i64, 2), note.interval);
    try testing.expectEqual(default_depth, note.depth);
    try testing.expectEqual(default_position, note.position);
    try testing.expectEqual(default_role, note.role);
    try testing.expect(note.active());
}

test "parse ignores a non-string prompt rather than rendering it" {
    const p = try parseStr("{\"note_prompt\":{\"nope\":1},\"note_interval\":1}");
    defer p.deinit();
    const note = parse(p.value);
    try testing.expectEqualStrings("", note.prompt);
    try testing.expect(!note.active());
}

test "parse clamps a negative depth to zero" {
    const p = try parseStr("{\"note_depth\":-4}");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0), parse(p.value).depth);
}

test "active rejects a whitespace-only note and a disabled interval" {
    try testing.expect(!(Note{ .prompt = "   \n\t" }).active());
    try testing.expect(!(Note{ .prompt = "x", .interval = 0 }).active());
    try testing.expect(!(Note{ .prompt = "x", .interval = -1 }).active());
    try testing.expect((Note{ .prompt = "x", .interval = 1 }).active());
}

test "shouldInject honours always, disabled, and the periodic interval" {
    const always = Note{ .prompt = "n", .interval = 1 };
    try testing.expect(shouldInject(always, 0));
    try testing.expect(shouldInject(always, 7));

    const off = Note{ .prompt = "n", .interval = 0 };
    try testing.expect(!shouldInject(off, 4));

    const every3 = Note{ .prompt = "n", .interval = 3 };
    try testing.expect(!shouldInject(every3, 1));
    try testing.expect(!shouldInject(every3, 2));
    try testing.expect(shouldInject(every3, 3));
    try testing.expect(shouldInject(every3, 6));
    try testing.expect(!shouldInject(every3, 7));
    try testing.expect(!shouldInject(every3, 0));

    const blank = Note{ .prompt = "", .interval = 1 };
    try testing.expect(!shouldInject(blank, 5));
}

test "injectionIndex places an in_chat note depth turns from the newest" {
    const note = Note{ .prompt = "n", .interval = 1, .position = .in_chat, .depth = 2 };
    try testing.expectEqual(@as(?usize, 8), injectionIndex(note, 10));

    const at_end = Note{ .prompt = "n", .interval = 1, .position = .in_chat, .depth = 0 };
    try testing.expectEqual(@as(?usize, 10), injectionIndex(at_end, 10));

    // Past the head pins at 0 rather than wrapping to a huge index.
    const deep = Note{ .prompt = "n", .interval = 1, .position = .in_chat, .depth = 99 };
    try testing.expectEqual(@as(?usize, 0), injectionIndex(deep, 10));
    try testing.expectEqual(@as(?usize, 0), injectionIndex(deep, 0));
}

test "injectionIndex is null for the anchor positions and an inactive note" {
    const before = Note{ .prompt = "n", .interval = 1, .position = .before_prompt, .depth = 2 };
    try testing.expectEqual(@as(?usize, null), injectionIndex(before, 10));

    const in_prompt = Note{ .prompt = "n", .interval = 1, .position = .in_prompt, .depth = 2 };
    try testing.expectEqual(@as(?usize, null), injectionIndex(in_prompt, 10));

    const blank = Note{ .prompt = "", .interval = 1, .position = .in_chat, .depth = 2 };
    try testing.expectEqual(@as(?usize, null), injectionIndex(blank, 10));

    const periodic = Note{ .prompt = "n", .interval = 4, .position = .in_chat, .depth = 1 };
    try testing.expectEqual(@as(?usize, null), injectionIndex(periodic, 5));
    try testing.expectEqual(@as(?usize, 3), injectionIndex(periodic, 4));
}

test "merge writes the note back and keeps the metadata the client does not model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"integrity":"abc","timedWorldInfo":{"x":1},"note_prompt":"old"}
    , .{});

    try merge(a, &root.object, .{ .prompt = "It is raining.", .interval = 3, .depth = 2, .position = .in_prompt, .role = .user });

    try testing.expectEqualStrings("It is raining.", root.object.get("note_prompt").?.string);
    try testing.expectEqual(@as(i64, 3), root.object.get("note_interval").?.integer);
    try testing.expectEqual(@as(i64, 2), root.object.get("note_depth").?.integer);
    try testing.expectEqual(@as(i64, 0), root.object.get("note_position").?.integer);
    try testing.expectEqual(@as(i64, 1), root.object.get("note_role").?.integer);
    // A chat stock still reads: the keys this client does not model survive the write.
    try testing.expectEqualStrings("abc", root.object.get("integrity").?.string);
    try testing.expect(root.object.get("timedWorldInfo") != null);
}

test "merge output parses back to the same note" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = std.json.Value{ .object = .empty };
    const want = Note{ .prompt = "Keep it short.", .interval = 5, .depth = 3, .position = .before_prompt, .role = .assistant };
    try merge(a, &root.object, want);

    const round = parse(root);
    try testing.expectEqualStrings(want.prompt, round.prompt);
    try testing.expectEqual(want.interval, round.interval);
    try testing.expectEqual(want.depth, round.depth);
    try testing.expectEqual(want.position, round.position);
    try testing.expectEqual(want.role, round.role);
}

test "parseOwned survives the source json being freed" {
    var note: Note = undefined;
    {
        const p = try parseStr("{\"note_prompt\":\"borrowed text\"}");
        defer p.deinit();
        note = try parseOwned(testing.allocator, p.value);
    }
    defer freeOwned(testing.allocator, note);
    try testing.expectEqualStrings("borrowed text", note.prompt);
}

test "parseOwned cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, _: u8) !void {
            const p = try std.json.parseFromSlice(std.json.Value, alloc, "{\"note_prompt\":\"x\"}", .{});
            defer p.deinit();
            const note = try parseOwned(alloc, p.value);
            freeOwned(alloc, note);
        }
    }.run, .{@as(u8, 0)});
}

test "merge cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, _: u8) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            var root = std.json.Value{ .object = .empty };
            try merge(a, &root.object, .{ .prompt = "note" });
        }
    }.run, .{@as(u8, 0)});
}

test "intervalFires ignores note emptiness while shouldInject requires text" {
    const empty_note = Note{ .prompt = "", .interval = 1 };
    try testing.expect(intervalFires(empty_note, 0));
    try testing.expect(!shouldInject(empty_note, 0));
    const filled = Note{ .prompt = "x", .interval = 3 };
    try testing.expect(intervalFires(filled, 6));
    try testing.expect(!intervalFires(filled, 5));
    try testing.expect(!intervalFires(.{ .prompt = "x", .interval = 0 }, 4));
}
