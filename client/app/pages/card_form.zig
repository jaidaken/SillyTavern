//! Pure card-editor model: the editable field set, the owned edit buffers, and the exact
//! `/api/characters/edit` request body. No ziex dependency, so `zig build test` proves it (ZX5);
//! card_editor.zig owns the fetch, the state machine and the re-render.
//!
//! THE CONTRACT THIS FILE ENCODES (read off src/endpoints/characters.js at HEAD 352812d31):
//! `charaFormatData` (:651) seeds the saved card from `json_data` and then `_.set`s every field it
//! knows UNCONDITIONALLY. So a field omitted from the body is not "left alone", it is written back
//! as that field's default: an absent `description` saves `''`, an absent `talkativeness` saves 0.5,
//! an absent `fav` saves false. json_data therefore only preserves the keys charaFormatData never
//! touches (character_book, foreign extensions); every field it does touch must be echoed back or it
//! is destroyed. That is why Passthrough carries fields the form never edits.

const std = @import("std");
const nav = @import("./dropdown_nav.zig");

/// How a field presents. `line` is a single-line input, `area` a textarea, `choice` the dropdown.
pub const Kind = enum { line, area, choice };

/// The editable fields, in render order. The tag is the form identity: it names the DOM control
/// (`data-card-field`), so markup, handler and body all key off this one enum.
pub const Field = enum {
    name,
    description,
    first_mes,
    personality,
    scenario,
    mes_example,
    creator_notes,
    system_prompt,
    post_history_instructions,
    depth_prompt_prompt,
    depth_prompt_depth,
    depth_prompt_role,
    creator,
    character_version,
    tags,
    world,
};

pub const Spec = struct {
    field: Field,
    label: []const u8,
    kind: Kind,
    /// The one-line hint under the control. Says what the field does for the model, in the user's
    /// vocabulary (WD68), not a restatement of the label.
    hint: []const u8 = "",
};

pub const specs = [_]Spec{
    .{ .field = .name, .label = "Name", .kind = .line, .hint = "What the model calls this character." },
    .{ .field = .description, .label = "Description", .kind = .area, .hint = "Who they are. Sent with every message." },
    .{ .field = .first_mes, .label = "First message", .kind = .area, .hint = "How a new conversation opens." },
    .{ .field = .personality, .label = "Personality", .kind = .area, .hint = "A short summary of temperament." },
    .{ .field = .scenario, .label = "Scenario", .kind = .area, .hint = "The situation the conversation starts in." },
    .{ .field = .mes_example, .label = "Example messages", .kind = .area, .hint = "Sample exchanges that teach the voice." },
    .{ .field = .creator_notes, .label = "Creator notes", .kind = .area, .hint = "Notes for humans. Never sent to the model." },
    .{ .field = .system_prompt, .label = "System prompt", .kind = .area, .hint = "Overrides the default system prompt for this character." },
    .{ .field = .post_history_instructions, .label = "Post-history instructions", .kind = .area, .hint = "Injected after the chat history." },
    .{ .field = .depth_prompt_prompt, .label = "Character note", .kind = .area, .hint = "Injected a fixed number of messages from the end." },
    .{ .field = .depth_prompt_depth, .label = "Note depth", .kind = .line, .hint = "How many messages from the end the note lands. Blank uses 4." },
    .{ .field = .depth_prompt_role, .label = "Note role", .kind = .choice, .hint = "Which speaker the note is attributed to." },
    .{ .field = .creator, .label = "Creator", .kind = .line, .hint = "Who made the card." },
    .{ .field = .character_version, .label = "Version", .kind = .line, .hint = "The card's own version label." },
    .{ .field = .tags, .label = "Tags", .kind = .line, .hint = "Comma separated." },
    // A non-empty world makes the server REPLACE data.character_book from that lorebook
    // (characters.js:714-726); blank only clears the binding (:703). The hint says so.
    .{ .field = .world, .label = "World info book", .kind = .line, .hint = "Lorebook to bind. Saving replaces the card's own book with it. Blank unbinds and leaves the book as it is." },
};

/// The role options for the character note, matching the original's depth_prompt_role select. Typed
/// as the dropdown's own Option so the component takes this slice directly.
pub const role_options = [_]nav.Option{
    .{ .value = "system", .label = "System" },
    .{ .value = "user", .label = "User" },
    .{ .value = "assistant", .label = "Character" },
};

pub fn specFor(f: Field) Spec {
    for (specs) |s| {
        if (s.field == f) return s;
    }
    unreachable;
}

/// Maps a `data-card-field` value back to its Field. Null for anything unrecognised.
pub fn fieldFromName(s: []const u8) ?Field {
    inline for (@typeInfo(Field).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, s)) return @field(Field, f.name);
    }
    return null;
}

const field_count = @typeInfo(Field).@"enum".fields.len;

/// The edit buffers: one owned string per field, plus the baseline they were loaded with so
/// `dirty` can answer without a second copy of the card.
pub const Form = struct {
    gpa: std.mem.Allocator,
    values: [field_count][]u8 = @splat(&.{}),
    baseline: [field_count][]u8 = @splat(&.{}),

    pub fn init(gpa: std.mem.Allocator) Form {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Form) void {
        for (&self.values) |*v| self.gpa.free(v.*);
        for (&self.baseline) |*v| self.gpa.free(v.*);
        self.values = @splat(&.{});
        self.baseline = @splat(&.{});
    }

    pub fn get(self: *const Form, f: Field) []const u8 {
        return self.values[@intFromEnum(f)];
    }

    pub fn set(self: *Form, f: Field, v: []const u8) !void {
        const copy = try self.gpa.dupe(u8, v);
        const slot = &self.values[@intFromEnum(f)];
        self.gpa.free(slot.*);
        slot.* = copy;
    }

    /// Load a field and mark the loaded text as the clean baseline.
    pub fn load(self: *Form, f: Field, v: []const u8) !void {
        try self.set(f, v);
        const copy = try self.gpa.dupe(u8, v);
        const slot = &self.baseline[@intFromEnum(f)];
        self.gpa.free(slot.*);
        slot.* = copy;
    }

    /// Re-baseline every field to its current text, after a save lands.
    pub fn markClean(self: *Form) !void {
        for (&self.values, &self.baseline) |v, *b| {
            const copy = try self.gpa.dupe(u8, v);
            self.gpa.free(b.*);
            b.* = copy;
        }
    }

    pub fn dirty(self: *const Form) bool {
        for (self.values, self.baseline) |v, b| {
            if (!std.mem.eql(u8, v, b)) return true;
        }
        return false;
    }
};

/// The card fields the editor never shows but MUST send back, or charaFormatData writes its
/// defaults over them. See the file header.
pub const Passthrough = struct {
    avatar_url: []const u8,
    /// The raw card JSON the PNG carried, echoed verbatim so foreign keys (character_book, other
    /// tools' extensions) survive the round trip. This is the same hidden field the original client
    /// posts (public/index.html:6188).
    json_data: []const u8 = "",
    chat: []const u8 = "",
    create_date: []const u8 = "",
    fav: bool = false,
    talkativeness: f64 = 0.5,
    alternate_greetings: []const []const u8 = &.{},
};

/// The server reads fav with `data.fav == 'true'` (characters.js:678), a LOOSE compare against the
/// STRING "true". A JSON boolean true fails it (`true == 'true'` is false in JS), so echoing the
/// card's own boolean back would silently clear the favourite. Send the word.
pub fn favString(fav: bool) []const u8 {
    return if (fav) "true" else "false";
}

/// The note depth, or null when the field is blank so the key is OMITTED. The server takes
/// `!isNaN(Number(x)) ? Number(x) : 4` (characters.js:708), and `Number('')` is 0, not NaN: sending
/// an empty string would save depth 0 while sending nothing correctly falls back to 4.
pub fn depthValue(text: []const u8) ?f64 {
    const t = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (t.len == 0) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

/// Tags render as one comma-separated line; the server splits a string body on commas and trims
/// (characters.js:679), so the line goes back as-is and round-trips.
pub fn tagsJoin(gpa: std.mem.Allocator, tags: []const []const u8) ![]u8 {
    return std.mem.join(gpa, ", ", tags);
}

/// A card value that may be a JSON string, number or bool, flattened to the text the form shows.
/// Real cards are loose here; a strict parse would fail the whole editor over one odd field.
pub fn valueText(gpa: std.mem.Allocator, v: ?std.json.Value) ![]u8 {
    const val = v orelse return gpa.dupe(u8, "");
    return switch (val) {
        .string, .number_string => |s| gpa.dupe(u8, s),
        .integer => |i| std.fmt.allocPrint(gpa, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(gpa, "{d}", .{f}),
        .bool => |b| gpa.dupe(u8, if (b) "true" else "false"),
        else => gpa.dupe(u8, ""),
    };
}

/// Same tolerance for fav, which a card may carry as a bool or as the string "true".
pub fn valueBool(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return switch (val) {
        .bool => |b| b,
        .string, .number_string => |s| std.mem.eql(u8, s, "true"),
        .integer => |i| i != 0,
        else => false,
    };
}

/// Same tolerance for talkativeness, which the server defaults to 0.5.
pub fn valueFloat(v: ?std.json.Value, default: f64) f64 {
    const val = v orelse return default;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .string, .number_string => |s| std.fmt.parseFloat(f64, s) catch default,
        else => default,
    };
}

/// The `/api/characters/edit` body. Every key charaFormatData reads is present, so nothing the form
/// does not show gets defaulted away. `depth_prompt_depth` is the one conditional key (see
/// depthValue), which is why the body is built in two shapes rather than one struct.
pub fn saveBodyAlloc(gpa: std.mem.Allocator, form: *const Form, p: Passthrough) ![]u8 {
    const common = .{
        .avatar_url = p.avatar_url,
        .ch_name = form.get(.name),
        .description = form.get(.description),
        .personality = form.get(.personality),
        .scenario = form.get(.scenario),
        .first_mes = form.get(.first_mes),
        .mes_example = form.get(.mes_example),
        .creator_notes = form.get(.creator_notes),
        .system_prompt = form.get(.system_prompt),
        .post_history_instructions = form.get(.post_history_instructions),
        .creator = form.get(.creator),
        .character_version = form.get(.character_version),
        .tags = form.get(.tags),
        .world = form.get(.world),
        .depth_prompt_prompt = form.get(.depth_prompt_prompt),
        .depth_prompt_role = form.get(.depth_prompt_role),
        .fav = favString(p.fav),
        .talkativeness = p.talkativeness,
        .alternate_greetings = p.alternate_greetings,
        .json_data = p.json_data,
        .chat = p.chat,
        .create_date = p.create_date,
    };
    if (depthValue(form.get(.depth_prompt_depth))) |d| {
        return std.json.Stringify.valueAlloc(gpa, .{
            .avatar_url = common.avatar_url,
            .ch_name = common.ch_name,
            .description = common.description,
            .personality = common.personality,
            .scenario = common.scenario,
            .first_mes = common.first_mes,
            .mes_example = common.mes_example,
            .creator_notes = common.creator_notes,
            .system_prompt = common.system_prompt,
            .post_history_instructions = common.post_history_instructions,
            .creator = common.creator,
            .character_version = common.character_version,
            .tags = common.tags,
            .world = common.world,
            .depth_prompt_prompt = common.depth_prompt_prompt,
            .depth_prompt_role = common.depth_prompt_role,
            .depth_prompt_depth = d,
            .fav = common.fav,
            .talkativeness = common.talkativeness,
            .alternate_greetings = common.alternate_greetings,
            .json_data = common.json_data,
            .chat = common.chat,
            .create_date = common.create_date,
        }, .{});
    }
    return std.json.Stringify.valueAlloc(gpa, common, .{});
}

/// The name the server rejects: `ch_name` empty, undefined or "." all 400 (characters.js:1197).
pub fn nameValid(name: []const u8) bool {
    const t = std.mem.trim(u8, name, &std.ascii.whitespace);
    return t.len > 0 and !std.mem.eql(u8, t, ".");
}

const testing = std.testing;

fn parseBody(gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, body, .{});
}

test "fav goes back as the string the server compares against, never a json boolean" {
    // characters.js:678 is `data.fav == 'true'`; a real boolean loses the flag.
    try testing.expectEqualStrings("true", favString(true));
    try testing.expectEqualStrings("false", favString(false));

    var form = Form.init(testing.allocator);
    defer form.deinit();
    try form.load(.name, "Aria");
    const body = try saveBodyAlloc(testing.allocator, &form, .{ .avatar_url = "a.png", .fav = true });
    defer testing.allocator.free(body);

    var parsed = try parseBody(testing.allocator, body);
    defer parsed.deinit();
    try testing.expectEqualStrings("true", parsed.value.object.get("fav").?.string);
}

test "a blank note depth omits the key so the server default of 4 survives" {
    // Number('') is 0, not NaN, so an empty string would save depth 0.
    try testing.expectEqual(@as(?f64, null), depthValue(""));
    try testing.expectEqual(@as(?f64, null), depthValue("   "));
    try testing.expectEqual(@as(?f64, null), depthValue("abc"));
    try testing.expectEqual(@as(f64, 7), depthValue("7").?);
    try testing.expectEqual(@as(f64, 2), depthValue(" 2 ").?);

    var form = Form.init(testing.allocator);
    defer form.deinit();
    try form.load(.name, "Aria");
    const blank = try saveBodyAlloc(testing.allocator, &form, .{ .avatar_url = "a.png" });
    defer testing.allocator.free(blank);
    var p1 = try parseBody(testing.allocator, blank);
    defer p1.deinit();
    try testing.expect(p1.value.object.get("depth_prompt_depth") == null);

    try form.set(.depth_prompt_depth, "3");
    const filled = try saveBodyAlloc(testing.allocator, &form, .{ .avatar_url = "a.png" });
    defer testing.allocator.free(filled);
    var p2 = try parseBody(testing.allocator, filled);
    defer p2.deinit();
    // Stringify writes a whole f64 without a decimal point, so it reads back as .integer.
    try testing.expectEqual(@as(f64, 3), valueFloat(p2.value.object.get("depth_prompt_depth"), -1));
}

test "the body carries every field charaFormatData would otherwise default away" {
    var form = Form.init(testing.allocator);
    defer form.deinit();
    try form.load(.name, "Aria");
    try form.load(.description, "A hedge witch.");

    const greetings = [_][]const u8{ "hello there", "well met" };
    const body = try saveBodyAlloc(testing.allocator, &form, .{
        .avatar_url = "aria.png",
        .json_data = "{\"data\":{\"character_book\":{\"entries\":[]}}}",
        .chat = "Aria - 2026-01-01",
        .create_date = "2026-01-01T00:00:00.000Z",
        .talkativeness = 0.9,
        .alternate_greetings = &greetings,
    });
    defer testing.allocator.free(body);

    var parsed = try parseBody(testing.allocator, body);
    defer parsed.deinit();
    const o = parsed.value.object;
    // Omitting any of these saves the field's default over the card's real value.
    try testing.expectEqualStrings("aria.png", o.get("avatar_url").?.string);
    try testing.expectEqualStrings("Aria", o.get("ch_name").?.string);
    try testing.expectEqualStrings("A hedge witch.", o.get("description").?.string);
    try testing.expectEqualStrings("Aria - 2026-01-01", o.get("chat").?.string);
    try testing.expectEqualStrings("2026-01-01T00:00:00.000Z", o.get("create_date").?.string);
    try testing.expectEqual(@as(f64, 0.9), o.get("talkativeness").?.float);
    try testing.expectEqual(@as(usize, 2), o.get("alternate_greetings").?.array.items.len);
    try testing.expectEqualStrings("well met", o.get("alternate_greetings").?.array.items[1].string);
    // json_data rides back verbatim, which is what keeps the character_book on the card.
    try testing.expectEqualStrings("{\"data\":{\"character_book\":{\"entries\":[]}}}", o.get("json_data").?.string);
    for ([_][]const u8{ "personality", "scenario", "first_mes", "mes_example", "creator_notes", "system_prompt", "post_history_instructions", "creator", "character_version", "tags", "world", "depth_prompt_prompt", "depth_prompt_role" }) |key| {
        try testing.expect(o.get(key) != null);
    }
}

test "tags round-trip through the comma-separated line the server splits" {
    const tags = [_][]const u8{ "witch", "fantasy", "mentor" };
    const joined = try tagsJoin(testing.allocator, &tags);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("witch, fantasy, mentor", joined);

    const empty = try tagsJoin(testing.allocator, &.{});
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "loose card values flatten to form text rather than failing the parse" {
    const gpa = testing.allocator;
    const s = try valueText(gpa, .{ .string = "hi" });
    defer gpa.free(s);
    try testing.expectEqualStrings("hi", s);
    const i = try valueText(gpa, .{ .integer = 42 });
    defer gpa.free(i);
    try testing.expectEqualStrings("42", i);
    const n = try valueText(gpa, null);
    defer gpa.free(n);
    try testing.expectEqualStrings("", n);
    const b = try valueText(gpa, .{ .bool = true });
    defer gpa.free(b);
    try testing.expectEqualStrings("true", b);

    // fav arrives as a bool from readFromV2, but a hand-edited card may carry the string.
    try testing.expect(valueBool(.{ .bool = true }));
    try testing.expect(valueBool(.{ .string = "true" }));
    try testing.expect(!valueBool(.{ .string = "false" }));
    try testing.expect(!valueBool(null));

    try testing.expectEqual(@as(f64, 0.5), valueFloat(null, 0.5));
    try testing.expectEqual(@as(f64, 0.9), valueFloat(.{ .float = 0.9 }, 0.5));
    try testing.expectEqual(@as(f64, 1), valueFloat(.{ .integer = 1 }, 0.5));
    try testing.expectEqual(@as(f64, 0.25), valueFloat(.{ .string = "0.25" }, 0.5));
    try testing.expectEqual(@as(f64, 0.5), valueFloat(.{ .string = "nonsense" }, 0.5));
}

test "the form tracks dirty against the loaded baseline and re-baselines on save" {
    var form = Form.init(testing.allocator);
    defer form.deinit();
    try form.load(.name, "Aria");
    try form.load(.description, "A hedge witch.");
    try testing.expect(!form.dirty());

    try form.set(.description, "A hedge witch who keeps bees.");
    try testing.expect(form.dirty());
    try testing.expectEqualStrings("A hedge witch who keeps bees.", form.get(.description));

    try form.markClean();
    try testing.expect(!form.dirty());

    // Setting the same text back is not a change.
    try form.set(.description, "A hedge witch who keeps bees.");
    try testing.expect(!form.dirty());
}

test "the name the server would 400 on is rejected before the request" {
    try testing.expect(nameValid("Aria"));
    try testing.expect(!nameValid(""));
    try testing.expect(!nameValid("   "));
    try testing.expect(!nameValid("."));
    try testing.expect(!nameValid(" . "));
}

fn buildSaveBody(gpa: std.mem.Allocator) !void {
    var form = Form.init(gpa);
    defer form.deinit();
    try form.load(.name, "Aria");
    try form.load(.description, "A hedge witch.");
    try form.set(.depth_prompt_depth, "3");
    try form.markClean();
    const greetings = [_][]const u8{ "hello there", "well met" };
    const body = try saveBodyAlloc(gpa, &form, .{
        .avatar_url = "aria.png",
        .json_data = "{\"name\":\"Aria\"}",
        .chat = "Aria - 2026-01-01",
        .alternate_greetings = &greetings,
    });
    gpa.free(body);
}

test "building the save body cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, buildSaveBody, .{});
}

fn joinTags(gpa: std.mem.Allocator) !void {
    const tags = [_][]const u8{ "witch", "fantasy" };
    const joined = try tagsJoin(gpa, &tags);
    gpa.free(joined);
}

test "joining tags cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, joinTags, .{});
}

fn flattenValue(gpa: std.mem.Allocator) !void {
    const s = try valueText(gpa, .{ .integer = 42 });
    gpa.free(s);
}

test "flattening a card value cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, flattenValue, .{});
}

test "every field has exactly one spec and its name round-trips through the dom key" {
    try testing.expectEqual(field_count, specs.len);
    inline for (@typeInfo(Field).@"enum".fields) |f| {
        const id = @field(Field, f.name);
        var seen: usize = 0;
        for (specs) |s| {
            if (s.field == id) seen += 1;
        }
        try testing.expectEqual(@as(usize, 1), seen);
        try testing.expectEqual(id, fieldFromName(f.name).?);
        try testing.expect(specFor(id).label.len > 0);
    }
    try testing.expect(fieldFromName("nonesuch") == null);
    try testing.expect(fieldFromName("") == null);
}
