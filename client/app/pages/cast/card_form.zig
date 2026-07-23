//! Pure card-editor model: the editable field set, the owned edit buffers, the tolerant read of a
//! card's own JSON, and the exact `/api/characters/edit` request body. No ziex dependency, so
//! `zig build test` proves it (ZX5); card_editor.zig owns the fetch, the state machine and the
//! re-render.
//!
//! WHY THE CARD IS READ AS A json.Value AND NOT A TYPED STRUCT (see readCard):
//! `/api/characters/get` hands back what processCharacter built (characters.js:418-437), and every
//! field except the ones the SERVER sets comes straight out of the PNG's own JSON, uncoerced
//! (`const character = jsonObject; character.create_date = jsonObject.create_date || ...`). So a card
//! another tool wrote can carry any shape at all in any field. Typed, ONE such field does not render
//! oddly: it fails the WHOLE parse and the editor shows its retry screen over a card that is fine.
//! That exact class shipped twice (the recent-chats date, the character list). An unreadable shape
//! must cost THAT FIELD and nothing else. `avatar` and `json_data` are the two the server sets
//! itself, and they stay strict on purpose: see readCard's own note.
//!
//! THE CONTRACT THIS FILE ENCODES (read off src/endpoints/characters.js at HEAD 352812d31):
//! `charaFormatData` (:651) seeds the saved card from `json_data` and then `_.set`s every field it
//! knows UNCONDITIONALLY. So a field omitted from the body is not "left alone", it is written back
//! as that field's default: an absent `description` saves `''`, an absent `talkativeness` saves 0.5,
//! an absent `fav` saves false. json_data therefore only preserves the keys charaFormatData never
//! touches (character_book, foreign extensions); every field it does touch must be echoed back or it
//! is destroyed. That is why Passthrough carries fields the form never edits.

const std = @import("std");
const nav = @import("../nav/dropdown_nav.zig");
const char_data = @import("./char_data.zig");

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

/// True when the card's note role is one the dropdown can actually show. A card may carry anything
/// there, and a value with no matching option renders a blank button face, so the caller falls back
/// to the server's own default rather than displaying nothing.
pub fn roleKnown(v: []const u8) bool {
    for (role_options) |o| {
        if (std.mem.eql(u8, o.value, v)) return true;
    }
    return false;
}

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
/// `dirty` can answer without a second copy of the card. The alternate greetings live here too, and
/// not beside the card's other passthrough data, precisely so `dirty` stays one question with one
/// answer: a greeting the user typed is an unsaved change exactly as a description is.
pub const Form = struct {
    gpa: std.mem.Allocator,
    values: [field_count][]u8 = @splat(&.{}),
    baseline: [field_count][]u8 = @splat(&.{}),
    greetings: std.ArrayList([]u8) = .empty,
    greetings_baseline: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Form {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Form) void {
        for (&self.values) |*v| self.gpa.free(v.*);
        for (&self.baseline) |*v| self.gpa.free(v.*);
        self.values = @splat(&.{});
        self.baseline = @splat(&.{});
        self.freeList(&self.greetings);
        self.freeList(&self.greetings_baseline);
    }

    fn freeList(self: *Form, list: *std.ArrayList([]u8)) void {
        for (list.items) |g| self.gpa.free(g);
        list.deinit(self.gpa);
        list.* = .empty;
    }

    fn cloneInto(self: *Form, dst: *std.ArrayList([]u8), src: []const []const u8) !void {
        var next: std.ArrayList([]u8) = .empty;
        errdefer {
            for (next.items) |g| self.gpa.free(g);
            next.deinit(self.gpa);
        }
        try next.ensureTotalCapacity(self.gpa, src.len);
        for (src) |s| next.appendAssumeCapacity(try self.gpa.dupe(u8, s));
        self.freeList(dst);
        dst.* = next;
    }

    /// Load the card's greetings and mark them as the clean baseline.
    pub fn loadGreetings(self: *Form, items: []const []const u8) !void {
        try self.cloneInto(&self.greetings, items);
        try self.cloneInto(&self.greetings_baseline, items);
    }

    pub fn greetingsSlice(self: *const Form) []const []const u8 {
        return @ptrCast(self.greetings.items);
    }

    pub fn greetingCount(self: *const Form) usize {
        return self.greetings.items.len;
    }

    /// The text of one greeting, or "" past the end (a stale index from a click that raced a
    /// removal must not read out of bounds).
    pub fn greeting(self: *const Form, i: usize) []const u8 {
        if (i >= self.greetings.items.len) return "";
        return self.greetings.items[i];
    }

    pub fn setGreeting(self: *Form, i: usize, text: []const u8) !void {
        if (i >= self.greetings.items.len) return;
        const copy = try self.gpa.dupe(u8, text);
        self.gpa.free(self.greetings.items[i]);
        self.greetings.items[i] = copy;
    }

    /// Append an empty greeting for the user to type into.
    pub fn addGreeting(self: *Form) !void {
        try self.greetings.ensureUnusedCapacity(self.gpa, 1);
        self.greetings.appendAssumeCapacity(try self.gpa.dupe(u8, ""));
    }

    pub fn removeGreeting(self: *Form, i: usize) void {
        if (i >= self.greetings.items.len) return;
        self.gpa.free(self.greetings.orderedRemove(i));
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
        try self.cloneInto(&self.greetings_baseline, self.greetingsSlice());
    }

    pub fn dirty(self: *const Form) bool {
        for (self.values, self.baseline) |v, b| {
            if (!std.mem.eql(u8, v, b)) return true;
        }
        if (self.greetings.items.len != self.greetings_baseline.items.len) return true;
        for (self.greetings.items, self.greetings_baseline.items) |v, b| {
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

/// The value at `key`, or null when the parent is not an object at all. A card whose `data` is a
/// string rather than an object costs its data.* fields, not the whole editor.
fn objField(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    const val = v orelse return null;
    return switch (val) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// The string at `key`, or "" for any other shape. Borrowed from the parse; copy it to retain.
fn strField(v: ?std.json.Value, key: []const u8) []const u8 {
    return char_data.jsonStr(objField(v, key) orelse return "");
}

/// One card as `/api/characters/get` returns it, flattened to what the form needs. Strings are
/// borrowed from the parse. See the file header for why nothing here is a typed struct field.
pub const Card = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    personality: []const u8 = "",
    scenario: []const u8 = "",
    first_mes: []const u8 = "",
    mes_example: []const u8 = "",
    creator_notes: []const u8 = "",
    system_prompt: []const u8 = "",
    post_history_instructions: []const u8 = "",
    creator: []const u8 = "",
    character_version: []const u8 = "",
    world: []const u8 = "",
    depth_prompt_prompt: []const u8 = "",
    depth: ?std.json.Value = null,
    role: ?std.json.Value = null,
    tags: ?std.json.Value = null,
    greetings: ?std.json.Value = null,
    chat: ?std.json.Value = null,
    create_date: ?std.json.Value = null,
    fav: ?std.json.Value = null,
    talkativeness: ?std.json.Value = null,
};

/// Reads a parsed card body into the fields the form shows. Every field is optional and every odd
/// shape degrades to empty, so no single field can cost the card.
///
/// `json_data` is NOT read here, and that is the deliberate asymmetry: the server sets it itself
/// (`character.json_data = imgData`, characters.js:426) and it is the key that carries the card's
/// character_book and any foreign tool's extensions through the save. Read loosely, a shape we could
/// not parse would flatten to "" and the save would then write that emptiness over the real book.
/// Failing the load is the safe direction, so card_editor requires it as a string before it will
/// mount the form. See cardJsonData.
pub fn readCard(root: std.json.Value) Card {
    const data = objField(root, "data");
    const ext = objField(data, "extensions");
    const dp = objField(ext, "depth_prompt");
    return .{
        .name = strField(root, "name"),
        .description = strField(root, "description"),
        .personality = strField(root, "personality"),
        .scenario = strField(root, "scenario"),
        .first_mes = strField(root, "first_mes"),
        .mes_example = strField(root, "mes_example"),
        .creator_notes = strField(data, "creator_notes"),
        .system_prompt = strField(data, "system_prompt"),
        .post_history_instructions = strField(data, "post_history_instructions"),
        .creator = strField(data, "creator"),
        .character_version = strField(data, "character_version"),
        .world = strField(ext, "world"),
        .depth_prompt_prompt = strField(dp, "prompt"),
        .depth = objField(dp, "depth"),
        .role = objField(dp, "role"),
        .tags = objField(root, "tags"),
        .greetings = objField(data, "alternate_greetings"),
        .chat = objField(root, "chat"),
        .create_date = objField(root, "create_date"),
        .fav = objField(root, "fav"),
        .talkativeness = objField(root, "talkativeness"),
    };
}

/// The card's own file JSON, which the save must echo back or the character_book dies. Null when the
/// body carries no string there, which means the response did not come from processCharacter and the
/// editor must not save over it. See readCard.
pub fn cardJsonData(root: std.json.Value) ?[]const u8 {
    return switch (objField(root, "json_data") orelse return null) {
        .string, .number_string => |s| s,
        else => null,
    };
}

/// The tags line the form shows. A card may carry tags as an array, as an already-joined string, or
/// as nothing; an array entry that is not a string is dropped rather than shown as a blank tag.
pub fn tagsText(gpa: std.mem.Allocator, v: ?std.json.Value) ![]u8 {
    const val = v orelse return gpa.dupe(u8, "");
    switch (val) {
        .string, .number_string => |s| return gpa.dupe(u8, s),
        .array => |arr| {
            var keep: std.ArrayList([]const u8) = .empty;
            defer keep.deinit(gpa);
            for (arr.items) |item| {
                const s = char_data.jsonStr(item);
                if (s.len > 0) try keep.append(gpa, s);
            }
            return tagsJoin(gpa, keep.items);
        },
        else => return gpa.dupe(u8, ""),
    }
}

/// The alternate greetings the form edits, each owned by the caller. A card may carry a bare string
/// instead of an array. An array entry that is not a string becomes an EMPTY greeting rather than
/// vanishing: the count is the card's, and an empty row is something the user can see and delete,
/// where a silent drop is not.
pub fn greetingsAlloc(gpa: std.mem.Allocator, v: ?std.json.Value) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |g| gpa.free(g);
        out.deinit(gpa);
    }
    const val = v orelse return out.toOwnedSlice(gpa);
    switch (val) {
        // ensureUnusedCapacity first: `append(dupe(...))` leaks the dupe when the append is the
        // allocation that fails, which is exactly what the alloc-failure oracle proves.
        .string, .number_string => |s| {
            try out.ensureUnusedCapacity(gpa, 1);
            out.appendAssumeCapacity(try gpa.dupe(u8, s));
        },
        .array => |arr| {
            try out.ensureUnusedCapacity(gpa, arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try gpa.dupe(u8, char_data.jsonStr(item)));
        },
        else => {},
    }
    return out.toOwnedSlice(gpa);
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
        .alternate_greetings = form.greetingsSlice(),
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
    try form.loadGreetings(&greetings);
    const body = try saveBodyAlloc(testing.allocator, &form, .{
        .avatar_url = "aria.png",
        .json_data = "{\"data\":{\"character_book\":{\"entries\":[]}}}",
        .chat = "Aria - 2026-01-01",
        .create_date = "2026-01-01T00:00:00.000Z",
        .talkativeness = 0.9,
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

// Every field here is a shape the server hands over untouched, straight from the PNG's own JSON
// (characters.js:426-430). Typed, any ONE of them failed the whole parse and the card would not open.
const hostile_card =
    \\{"name":null,"description":42,"personality":["a","b"],"scenario":{"x":1},
    \\ "first_mes":true,"mes_example":null,"tags":"solo, mystery","chat":1700000000000,
    \\ "create_date":1700000000000,"fav":"true","talkativeness":"0.9",
    \\ "json_data":"{\"data\":{\"character_book\":{\"entries\":[]}}}",
    \\ "data":{"creator_notes":null,"system_prompt":7,"creator":"someone",
    \\  "alternate_greetings":["real one",99,null],
    \\  "extensions":{"world":null,"depth_prompt":{"prompt":null,"depth":"3","role":5}}}}
;

test "a card with a null or numeric field loads, and the odd shape costs only that field" {
    const gpa = testing.allocator;
    var parsed = try parseBody(gpa, hostile_card);
    defer parsed.deinit();
    const c = readCard(parsed.value);

    // Every unreadable shape reads as empty rather than failing the card.
    try testing.expectEqualStrings("", c.name);
    try testing.expectEqualStrings("", c.description);
    try testing.expectEqualStrings("", c.personality);
    try testing.expectEqualStrings("", c.scenario);
    try testing.expectEqualStrings("", c.first_mes);
    try testing.expectEqualStrings("", c.creator_notes);
    try testing.expectEqualStrings("", c.system_prompt);
    try testing.expectEqualStrings("", c.world);
    try testing.expectEqualStrings("", c.depth_prompt_prompt);

    // The readable fields beside them are untouched, which is the whole point.
    try testing.expectEqualStrings("someone", c.creator);
    try testing.expect(valueBool(c.fav));
    try testing.expectEqual(@as(f64, 0.9), valueFloat(c.talkativeness, 0.5));

    const depth = try valueText(gpa, c.depth);
    defer gpa.free(depth);
    try testing.expectEqualStrings("3", depth);

    // A numeric create_date is the exact shape that blanked the recent-chats list.
    const created = try valueText(gpa, c.create_date);
    defer gpa.free(created);
    try testing.expectEqualStrings("1700000000000", created);
}

test "a card whose data or extensions is not an object costs those fields, not the card" {
    const gpa = testing.allocator;
    var parsed = try parseBody(gpa, "{\"name\":\"Aria\",\"data\":\"not an object\"}");
    defer parsed.deinit();
    const c = readCard(parsed.value);
    try testing.expectEqualStrings("Aria", c.name);
    try testing.expectEqualStrings("", c.creator);
    try testing.expectEqualStrings("", c.world);
    try testing.expect(c.greetings == null);

    var p2 = try parseBody(gpa, "{\"name\":\"Aria\",\"data\":{\"extensions\":5}}");
    defer p2.deinit();
    const c2 = readCard(p2.value);
    try testing.expectEqualStrings("Aria", c2.name);
    try testing.expectEqualStrings("", c2.world);

    // A body that is not an object at all still reads, as an empty card.
    var p3 = try parseBody(gpa, "[1,2,3]");
    defer p3.deinit();
    const c3 = readCard(p3.value);
    try testing.expectEqualStrings("", c3.name);
}

test "json_data is required as a string because the save would otherwise erase the card's book" {
    const gpa = testing.allocator;
    var good = try parseBody(gpa, "{\"json_data\":\"{\\\"name\\\":\\\"Aria\\\"}\"}");
    defer good.deinit();
    try testing.expectEqualStrings("{\"name\":\"Aria\"}", cardJsonData(good.value).?);

    // Absent, null or a non-string: the response did not come from processCharacter, and echoing ""
    // back would write an empty card over the real one. Loud beats lossy.
    for ([_][]const u8{ "{}", "{\"json_data\":null}", "{\"json_data\":{\"name\":\"Aria\"}}", "[]" }) |body| {
        var p = try parseBody(gpa, body);
        defer p.deinit();
        try testing.expect(cardJsonData(p.value) == null);
    }
}

test "tags read from an array, from a joined string, or from neither" {
    const gpa = testing.allocator;
    var p = try parseBody(gpa, "{\"tags\":[\"witch\",\"fantasy\"]}");
    defer p.deinit();
    const arr = try tagsText(gpa, readCard(p.value).tags);
    defer gpa.free(arr);
    try testing.expectEqualStrings("witch, fantasy", arr);

    // A non-string entry is dropped: a blank tag would round-trip as a tag the card never had.
    var p2 = try parseBody(gpa, "{\"tags\":[\"witch\",42,null,\"coastal\"]}");
    defer p2.deinit();
    const mixed = try tagsText(gpa, readCard(p2.value).tags);
    defer gpa.free(mixed);
    try testing.expectEqualStrings("witch, coastal", mixed);

    var p3 = try parseBody(gpa, hostile_card);
    defer p3.deinit();
    const line = try tagsText(gpa, readCard(p3.value).tags);
    defer gpa.free(line);
    try testing.expectEqualStrings("solo, mystery", line);

    const none = try tagsText(gpa, null);
    defer gpa.free(none);
    try testing.expectEqualStrings("", none);

    var p4 = try parseBody(gpa, "{\"tags\":{\"not\":\"a list\"}}");
    defer p4.deinit();
    const odd = try tagsText(gpa, readCard(p4.value).tags);
    defer gpa.free(odd);
    try testing.expectEqualStrings("", odd);
}

test "greetings read from a card and keep the card's own count" {
    const gpa = testing.allocator;
    var p = try parseBody(gpa, hostile_card);
    defer p.deinit();
    const g = try greetingsAlloc(gpa, readCard(p.value).greetings);
    defer {
        for (g) |s| gpa.free(s);
        gpa.free(g);
    }
    // Three in, three out: the two unreadable entries become empty rows the user can see and
    // delete, where dropping them would quietly rewrite the card on the next save.
    try testing.expectEqual(@as(usize, 3), g.len);
    try testing.expectEqualStrings("real one", g[0]);
    try testing.expectEqualStrings("", g[1]);
    try testing.expectEqualStrings("", g[2]);

    // A card carrying a bare string reads as the one greeting it is.
    var p2 = try parseBody(gpa, "{\"data\":{\"alternate_greetings\":\"just one\"}}");
    defer p2.deinit();
    const one = try greetingsAlloc(gpa, readCard(p2.value).greetings);
    defer {
        for (one) |s| gpa.free(s);
        gpa.free(one);
    }
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("just one", one[0]);

    const none = try greetingsAlloc(gpa, null);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "the greeting editor adds, edits and removes, and the body carries the result" {
    const gpa = testing.allocator;
    var form = Form.init(gpa);
    defer form.deinit();
    try form.load(.name, "Aria");
    const loaded = [_][]const u8{ "The fog is in.", "Mind the step." };
    try form.loadGreetings(&loaded);
    try testing.expectEqual(@as(usize, 2), form.greetingCount());
    try testing.expect(!form.dirty());

    try form.addGreeting();
    try testing.expectEqual(@as(usize, 3), form.greetingCount());
    try testing.expectEqualStrings("", form.greeting(2));
    try form.setGreeting(2, "The lamp is out.");
    try testing.expectEqualStrings("The lamp is out.", form.greeting(2));

    form.removeGreeting(0);
    try testing.expectEqual(@as(usize, 2), form.greetingCount());
    // orderedRemove, so the survivors keep the card's order rather than a swap-remove shuffle.
    try testing.expectEqualStrings("Mind the step.", form.greeting(0));
    try testing.expectEqualStrings("The lamp is out.", form.greeting(1));

    const body = try saveBodyAlloc(gpa, &form, .{ .avatar_url = "a.png" });
    defer gpa.free(body);
    var parsed = try parseBody(gpa, body);
    defer parsed.deinit();
    const arr = parsed.value.object.get("alternate_greetings").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    try testing.expectEqualStrings("Mind the step.", arr.items[0].string);
    try testing.expectEqualStrings("The lamp is out.", arr.items[1].string);

    // An index past the end is a click that raced a removal, not a crash.
    try testing.expectEqualStrings("", form.greeting(99));
    try form.setGreeting(99, "nowhere");
    form.removeGreeting(99);
    try testing.expectEqual(@as(usize, 2), form.greetingCount());
}

test "an edited greeting is an unsaved change, and a save re-baselines it" {
    var form = Form.init(testing.allocator);
    defer form.deinit();
    try form.load(.name, "Aria");
    const loaded = [_][]const u8{"The fog is in."};
    try form.loadGreetings(&loaded);
    try testing.expect(!form.dirty());

    try form.setGreeting(0, "The fog is out.");
    try testing.expect(form.dirty());
    try form.markClean();
    try testing.expect(!form.dirty());

    // Adding one is a change even though every existing row still matches.
    try form.addGreeting();
    try testing.expect(form.dirty());
    try form.markClean();
    try testing.expect(!form.dirty());

    form.removeGreeting(0);
    try testing.expect(form.dirty());
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

test "a note role the dropdown cannot show falls back rather than rendering a blank face" {
    try testing.expect(roleKnown("system"));
    try testing.expect(roleKnown("user"));
    try testing.expect(roleKnown("assistant"));
    // The shapes a hostile card reaches the dropdown with.
    try testing.expect(!roleKnown(""));
    try testing.expect(!roleKnown("5"));
    try testing.expect(!roleKnown("System"));
    try testing.expect(!roleKnown("narrator"));
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
    const greetings = [_][]const u8{ "hello there", "well met" };
    try form.loadGreetings(&greetings);
    try form.addGreeting();
    try form.setGreeting(2, "third");
    form.removeGreeting(0);
    try form.markClean();
    const body = try saveBodyAlloc(gpa, &form, .{
        .avatar_url = "aria.png",
        .json_data = "{\"name\":\"Aria\"}",
        .chat = "Aria - 2026-01-01",
    });
    gpa.free(body);
}

test "building the save body cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, buildSaveBody, .{});
}

fn readHostileCard(gpa: std.mem.Allocator) !void {
    var parsed = try parseBody(gpa, hostile_card);
    defer parsed.deinit();
    const c = readCard(parsed.value);
    const line = try tagsText(gpa, c.tags);
    defer gpa.free(line);
    const g = try greetingsAlloc(gpa, c.greetings);
    defer {
        for (g) |s| gpa.free(s);
        gpa.free(g);
    }
    const depth = try valueText(gpa, c.depth);
    gpa.free(depth);
}

test "reading a hostile card cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, readHostileCard, .{});
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
