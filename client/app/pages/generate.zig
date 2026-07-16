//! Pure prompt assembly and text-completion request-body builder for the send loop. No zx import, so
//! this whole module runs under `zig build test` (ZX5 split); char_api.zig (impure) fetches the
//! settings blob, the deep card, and the persona, then calls in, and the SSE pump stays in the JS
//! glue (ZX16).
//!
//! Scope this phase: the textgen family only (main_api == "textgenerationwebui"). The openai-chat
//! and kobold-horde families use other endpoints and body shapes and are out of scope; extraction
//! returns error.UnsupportedApi for them rather than guessing.
//!
//! The prompt SHAPE lives in templates.zig (the instruct/context model the formatting panel edits)
//! and the macro resolver in macros.zig; this file orders the blocks and enforces the budget. Ctx and
//! substituteMacros are re-exported here so char_api keeps one import for the assembly call.

const std = @import("std");

const macros = @import("./macros.zig");
const templates = @import("./templates.zig");
const authors_note = @import("./authors_note.zig");

const Allocator = std.mem.Allocator;

pub const Ctx = macros.Ctx;
pub const substituteMacros = macros.substituteMacros;
pub const Role = templates.Role;
pub const Templates = templates.Templates;
pub const Note = authors_note.Note;

/// The backend connection pulled out of the settings blob. `api_type`/`api_server` are owned; the
/// samplers are plain scalars coerced from the blob with backend-neutral defaults when a field is
/// absent. Free with `freeConnection`.
pub const Connection = struct {
    api_type: []u8,
    api_server: []u8,
    max_context: i64,
    max_tokens: i64,
    temperature: f64,
    top_p: f64,
    top_k: i64,
    min_p: f64,
    rep_pen: f64,
};

pub fn freeConnection(alloc: Allocator, conn: Connection) void {
    alloc.free(conn.api_type);
    alloc.free(conn.api_server);
}

pub const ConnectionError = error{ ParseFailed, NotAnObject, UnsupportedApi, MissingConnection } || Allocator.Error;

/// The connection lives inside the `settings` string of /api/settings/get (the same blob
/// `extractPersonas` reads). For the textgen family the active backend is
/// `textgenerationwebui_settings.type`, its URL is `textgenerationwebui_settings.server_urls[type]`,
/// and the samplers sit alongside them; `amount_gen` at the root is the response length. A missing
/// `main_api`, or one that is not "textgenerationwebui", is UnsupportedApi; a textgen family with no
/// `type` is MissingConnection. An empty server URL is allowed (backend configured but not pointed
/// yet) so the caller can render a "not connected" status rather than fail extraction.
pub fn extractConnection(alloc: Allocator, settings_str: []const u8) ConnectionError!Connection {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, settings_str, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseFailed,
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    if (!std.mem.eql(u8, strField(root, "main_api"), "textgenerationwebui")) return error.UnsupportedApi;

    const tg = switch (root.get("textgenerationwebui_settings") orelse return error.MissingConnection) {
        .object => |o| o,
        else => return error.MissingConnection,
    };

    const type_str = strField(tg, "type");
    if (type_str.len == 0) return error.MissingConnection;
    const server = serverUrl(tg, type_str);

    const api_type = try alloc.dupe(u8, type_str);
    errdefer alloc.free(api_type);
    const api_server = try alloc.dupe(u8, server);
    errdefer alloc.free(api_server);

    return .{
        .api_type = api_type,
        .api_server = api_server,
        .max_context = numI64(root, "max_context", 8192),
        .max_tokens = numI64(root, "amount_gen", 512),
        .temperature = numF64(tg, "temp", 1.0),
        .top_p = numF64(tg, "top_p", 1.0),
        .top_k = numI64(tg, "top_k", 0),
        .min_p = numF64(tg, "min_p", 0.0),
        .rep_pen = numF64(tg, "rep_pen", 1.0),
    };
}

fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (obj.get(key) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

fn serverUrl(tg: std.json.ObjectMap, type_str: []const u8) []const u8 {
    const urls = switch (tg.get("server_urls") orelse return "") {
        .object => |o| o,
        else => return "",
    };
    return strField(urls, type_str);
}

fn numF64(obj: std.json.ObjectMap, key: []const u8, default: f64) f64 {
    return switch (obj.get(key) orelse return default) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => default,
    };
}

fn numI64(obj: std.json.ObjectMap, key: []const u8, default: i64) i64 {
    return switch (obj.get(key) orelse return default) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

/// One history turn for the prompt: who spoke, their display name, and the message text.
///
/// `role` is what picks the instruct sequence the turn wraps in (probe tear 1). It is NOT derivable
/// from `name`: a narrator line and the character's own line can carry the same name, so the caller
/// passes the message's own is_user/is_system flags through instead of the wrapper guessing.
pub const PromptMsg = struct {
    name: []const u8,
    mes: []const u8,
    role: Role = .assistant,
};

/// The client has no tokenizer, so the prompt window is bounded by a character budget approximated
/// from the model's context size. ~3.5 chars/token is the classic client's rough estimate; an
/// over-fill is clamped by llama.cpp truncating server-side, not fatal.
const TOKEN_CHARS_NUM: usize = 7;
const TOKEN_CHARS_DEN: usize = 2;

/// Character budget for the whole prompt: the context size minus the response reserve, in chars.
/// `max_context` is mined from the settings blob (the classic client writes the user's configured
/// size there); a missing or non-positive value falls back to the classic 8192 default.
pub fn promptCharBudget(conn: Connection) usize {
    const ctx_tokens: usize = if (conn.max_context > 0) @intCast(conn.max_context) else 8192;
    const resp_tokens: usize = if (conn.max_tokens > 0) @intCast(conn.max_tokens) else 0;
    const hist_tokens = ctx_tokens -| resp_tokens;
    return (hist_tokens *| TOKEN_CHARS_NUM) / TOKEN_CHARS_DEN;
}

/// The newest suffix of `history` whose cumulative WRAPPED length fits `budget_chars`. Walks
/// oldest-first from the tail so the freshest turns survive a tight budget; always keeps at least the
/// last message so a send never ships an empty history. This is what decouples the prompt from the
/// display window (invariant 2): the caller feeds the full spine window, not the on-screen tail.
///
/// The cost is TEMPLATE-AWARE (probe tear 6). Charging every turn a flat `name + ": " + mes + "\n"`
/// under-counts a ChatML turn nearly 3x, so the window over-fills, the backend truncates the OLDEST
/// history to fit its real context, and the prompt silently loses the turns this function exists to
/// protect. `tpl` must be the same template the assembly wraps with, or the count is fiction.
pub fn selectWindow(history: []const PromptMsg, budget_chars: usize, tpl: templates.Instruct) []const PromptMsg {
    if (history.len == 0) return history;
    var used: usize = 0;
    var i: usize = history.len;
    while (i > 0) {
        const m = history[i - 1];
        const cost = templates.wrapCost(tpl, m.role, m.name, m.mes);
        if (i != history.len and used + cost > budget_chars) break;
        used += cost;
        i -= 1;
    }
    return history[i..];
}

/// Everything about prompt SHAPE that is not the card content or the history: the instruct/context
/// templates the formatting panel edits, and the chat's author's note. Defaulted, so a caller that
/// has neither still assembles the classic `Name: mes` prompt.
pub const Shape = struct {
    tpl: Templates = .{},
    note: Note = .{},
};

/// Builds the text-completion prompt with no budget cap. Owned result.
pub fn buildPrompt(alloc: Allocator, ctx: Ctx, history: []const PromptMsg, shape: Shape) Allocator.Error![]u8 {
    return buildPromptBudgeted(alloc, ctx, history, std.math.maxInt(usize), shape);
}

/// The prompt, in the order the classic client assembles it:
///   1. the story string (system, world-info, card fields, persona, author's-note anchors), wrapped
///      in the instruct template's story-string sequences
///   2. the example dialogue, each block under the context template's example separator
///   3. `chat_start`
///   4. the chat history, each turn wrapped in the sequence its ROLE selects, trimmed oldest-first
///      to the remaining budget
///   5. an `in_chat` author's note, inserted at its depth AFTER the trim
///   6. the continuation prefix that primes the model to answer
///
/// The system block is built in full first (it is per-card and small) and the author's note is
/// reserved out of the budget BEFORE the history walk, so neither can be silently trimmed: the note
/// is a control instruction, and losing it would change the reply with nothing to point at. The
/// remaining budget bounds the history alone. Owned result.
pub fn buildPromptBudgeted(alloc: Allocator, ctx: Ctx, history: []const PromptMsg, budget_chars: usize, shape: Shape) Allocator.Error![]u8 {
    const instruct = shape.tpl.instruct;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const story = try templates.renderStoryString(alloc, shape.tpl.context.story_string, ctx);
    defer alloc.free(story);
    const wrapped_story = try templates.wrapStoryString(alloc, instruct, story);
    defer alloc.free(wrapped_story);
    try out.appendSlice(alloc, wrapped_story);

    try appendExamples(alloc, &out, ctx, shape.tpl.context.example_separator);
    if (shape.tpl.context.chat_start.len > 0) {
        const start = try substituteMacros(alloc, shape.tpl.context.chat_start, ctx);
        defer alloc.free(start);
        try out.appendSlice(alloc, start);
        try out.append(alloc, '\n');
    }

    const note_cost = noteCost(instruct, shape.note, history.len);
    const windowed = selectWindow(history, budget_chars -| out.items.len -| note_cost, instruct);
    const inject_at = authors_note.injectionIndex(shape.note, windowed.len);
    for (windowed, 0..) |m, i| {
        if (inject_at != null and inject_at.? == i) try appendNote(alloc, &out, instruct, shape.note);
        try templates.appendWrapped(alloc, &out, instruct, m.role, m.name, m.mes);
    }
    if (inject_at != null and inject_at.? >= windowed.len) try appendNote(alloc, &out, instruct, shape.note);

    const prefix = try templates.continuationPrefix(alloc, instruct, ctx.char);
    defer alloc.free(prefix);
    try out.appendSlice(alloc, prefix);
    return out.toOwnedSlice(alloc);
}

/// The byte cost of an in_chat note, reserved from the budget before the history walk. Zero for the
/// anchor positions: those already rode into the story string, which is built in full.
fn noteCost(tpl: templates.Instruct, note: Note, history_len: usize) usize {
    if (authors_note.injectionIndex(note, history_len) == null) return 0;
    return templates.wrapCost(tpl, note.role.toTemplateRole(), "", note.prompt);
}

fn appendNote(alloc: Allocator, out: *std.ArrayList(u8), tpl: templates.Instruct, note: Note) Allocator.Error!void {
    try templates.appendWrapped(alloc, out, tpl, note.role.toTemplateRole(), "", note.prompt);
}

/// The card's example dialogue. The classic client splits the field on `<START>` and gives each block
/// the context template's example separator as a heading (instruct-mode.js:513), which is what keeps
/// a multi-block example from reading as one run-on exchange.
fn appendExamples(alloc: Allocator, out: *std.ArrayList(u8), ctx: Ctx, separator: []const u8) Allocator.Error!void {
    if (ctx.mes_example.len == 0) return;
    const subbed = try substituteMacros(alloc, ctx.mes_example, ctx);
    defer alloc.free(subbed);
    if (std.mem.trim(u8, subbed, " \t\r\n").len == 0) return;

    var it = std.mem.splitSequence(u8, subbed, "<START>");
    while (it.next()) |raw| {
        const block = std.mem.trim(u8, raw, " \t\r\n");
        if (block.len == 0) continue;
        if (separator.len > 0) {
            try out.appendSlice(alloc, separator);
            try out.append(alloc, '\n');
        }
        try out.appendSlice(alloc, block);
        try out.append(alloc, '\n');
    }
}

/// Builds the JSON body for POST /api/backends/text-completions/generate. `stream` is always true:
/// the send loop reads the model SSE the server pipes back unchanged. The samplers ride from the
/// connection; the server filters them per backend type. Owned result.
///
/// `stop` carries the instruct template's stop sequence (probe tear 8: the body had no stop field at
/// all, so a ChatML template's `<|im_end|>` never reached the backend and the model ran straight past
/// the end of its turn, hallucinating the user's next line). Sent under both spellings because the
/// backends disagree: llama.cpp and the OpenAI-shaped servers read `stop`, ooba/kobold read
/// `stopping_strings`. An empty sequence sends an empty array, which every backend treats as "no
/// custom stops" rather than as a stop on the empty string.
pub fn buildRequestBody(alloc: Allocator, conn: Connection, prompt: []const u8, stop: []const []const u8) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .prompt = prompt,
        .max_new_tokens = conn.max_tokens,
        .max_tokens = conn.max_tokens,
        .truncation_length = conn.max_context,
        .max_context_length = conn.max_context,
        .stream = true,
        .api_type = conn.api_type,
        .api_server = conn.api_server,
        .temperature = conn.temperature,
        .top_p = conn.top_p,
        .top_k = conn.top_k,
        .min_p = conn.min_p,
        .rep_pen = conn.rep_pen,
        .repetition_penalty = conn.rep_pen,
        .stop = stop,
        .stopping_strings = stop,
    }, .{});
}

/// The stop sequences a template implies. The instruct stop_sequence is the real one; a template
/// that sets none yields an empty slice rather than a stop on "". Borrowed from `tpl`.
pub fn stopSequences(tpl: templates.Instruct, buf: *[1][]const u8) []const []const u8 {
    if (!tpl.enabled or tpl.stop_sequence.len == 0) return &.{};
    buf[0] = tpl.stop_sequence;
    return buf[0..1];
}

const testing = std.testing;

test "extractConnection reads type, server_urls, and coerced samplers" {
    const settings =
        \\{"main_api":"textgenerationwebui","amount_gen":320,"max_context":16384,
        \\ "textgenerationwebui_settings":{"type":"llamacpp",
        \\   "server_urls":{"llamacpp":"http://127.0.0.1:8080","ooba":"http://x"},
        \\   "temp":0.8,"top_p":0.95,"top_k":40,"min_p":0.05,"rep_pen":1.1}}
    ;
    const conn = try extractConnection(testing.allocator, settings);
    defer freeConnection(testing.allocator, conn);
    try testing.expectEqualStrings("llamacpp", conn.api_type);
    try testing.expectEqualStrings("http://127.0.0.1:8080", conn.api_server);
    try testing.expectEqual(@as(i64, 16384), conn.max_context);
    try testing.expectEqual(@as(i64, 320), conn.max_tokens);
    try testing.expectEqual(@as(f64, 0.8), conn.temperature);
    try testing.expectEqual(@as(f64, 0.95), conn.top_p);
    try testing.expectEqual(@as(i64, 40), conn.top_k);
    try testing.expectEqual(@as(f64, 0.05), conn.min_p);
    try testing.expectEqual(@as(f64, 1.1), conn.rep_pen);
}

test "extractConnection defaults absent samplers and allows an empty server" {
    const settings =
        \\{"main_api":"textgenerationwebui","textgenerationwebui_settings":{"type":"ooba","server_urls":{}}}
    ;
    const conn = try extractConnection(testing.allocator, settings);
    defer freeConnection(testing.allocator, conn);
    try testing.expectEqualStrings("ooba", conn.api_type);
    try testing.expectEqualStrings("", conn.api_server);
    try testing.expectEqual(@as(i64, 8192), conn.max_context);
    try testing.expectEqual(@as(i64, 512), conn.max_tokens);
    try testing.expectEqual(@as(f64, 1.0), conn.temperature);
    try testing.expectEqual(@as(i64, 0), conn.top_k);
}

test "extractConnection rejects other families and malformed blobs" {
    try testing.expectError(error.UnsupportedApi, extractConnection(testing.allocator,
        \\{"main_api":"openai","textgenerationwebui_settings":{"type":"ooba"}}
    ));
    try testing.expectError(error.UnsupportedApi, extractConnection(testing.allocator, "{}"));
    try testing.expectError(error.MissingConnection, extractConnection(testing.allocator,
        \\{"main_api":"textgenerationwebui"}
    ));
    try testing.expectError(error.MissingConnection, extractConnection(testing.allocator,
        \\{"main_api":"textgenerationwebui","textgenerationwebui_settings":{"server_urls":{}}}
    ));
    try testing.expectError(error.ParseFailed, extractConnection(testing.allocator, "{nope"));
    try testing.expectError(error.NotAnObject, extractConnection(testing.allocator, "42"));
}

test "extractConnection cleans up on every allocation failure" {
    const settings =
        \\{"main_api":"textgenerationwebui","textgenerationwebui_settings":{"type":"ooba","server_urls":{"ooba":"http://x"}}}
    ;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, s: []const u8) !void {
            const conn = try extractConnection(alloc, s);
            freeConnection(alloc, conn);
        }
    }.run, .{@as([]const u8, settings)});
}

test "extractConnection never panics or leaks on arbitrary bytes" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var buf: [128]u8 = undefined;
    for (0..5000) |_| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        if (extractConnection(testing.allocator, buf[0..len])) |conn| {
            freeConnection(testing.allocator, conn);
        } else |_| {}
    }
}

// The macro resolver's own tests live in macros.zig, where the resolver moved.

const chatml = templates.Instruct{
    .enabled = true,
    .input_sequence = "<|im_start|>user",
    .output_sequence = "<|im_start|>assistant",
    .system_sequence = "<|im_start|>system",
    .input_suffix = "<|im_end|>\n",
    .output_suffix = "<|im_end|>\n",
    .system_suffix = "<|im_end|>\n",
    .stop_sequence = "<|im_end|>",
    .story_string_prefix = "<|im_start|>system",
    .story_string_suffix = "<|im_end|>\n",
    .wrap = true,
    .names_behavior = .none,
};

fn chatmlShape() Shape {
    return .{ .tpl = .{
        .instruct = chatml,
        .context = .{ .story_string = templates.default_story_string },
    } };
}

test "buildPrompt assembles system block, history, and the char prefix untemplated" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie", .description = "{{char}} is a diver.", .personality = "warm", .scenario = "the shoals" };
    const history = [_]PromptMsg{
        .{ .name = "Rita", .mes = "The lantern gutters.", .role = .assistant },
        .{ .name = "Jamie", .mes = "What is that?", .role = .user },
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, .{});
    defer testing.allocator.free(out);
    const want =
        "Rita is a diver.\n" ++
        "warm\n" ++
        "the shoals\n" ++
        "Rita: The lantern gutters.\n" ++
        "Jamie: What is that?\n" ++
        "Rita:";
    try testing.expectEqualStrings(want, out);
}

test "buildPrompt omits empty card fields and still primes the char" {
    const ctx = Ctx{ .char = "Rita" };
    const out = try buildPrompt(testing.allocator, ctx, &.{}, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita:", out);
}

test "buildPrompt wraps every turn in the role's own ChatML sequence" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie", .description = "A diver." };
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "Hi.", .role = .user },
        .{ .name = "Rita", .mes = "Hello.", .role = .assistant },
        .{ .name = "Rita", .mes = "The lamp dies.", .role = .system },
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, chatmlShape());
    defer testing.allocator.free(out);
    const want =
        "<|im_start|>system\nA diver.\n<|im_end|>\n" ++
        "<|im_start|>user\nHi.<|im_end|>\n" ++
        "<|im_start|>assistant\nHello.<|im_end|>\n" ++
        "<|im_start|>system\nThe lamp dies.<|im_end|>\n" ++
        "<|im_start|>assistant\n";
    try testing.expectEqualStrings(want, out);
}

test "buildPrompt renders the story string rather than emitting literal handlebars" {
    // The tear: substituteMacros alone leaves `{{#if description}}` in the prompt.
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .system = "You are {{char}}." };
    const out = try buildPrompt(testing.allocator, ctx, &.{}, chatmlShape());
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "{{#if") == null);
    try testing.expect(std.mem.indexOf(u8, out, "{{char}}") == null);
    try testing.expect(std.mem.indexOf(u8, out, "You are Rita.") != null);
}

test "buildPrompt gives each example block the context separator" {
    const ctx = Ctx{ .char = "Rita", .mes_example = "<START>\nRita: one\n<START>\nRita: two" };
    const shape = Shape{ .tpl = .{ .context = .{ .story_string = "", .example_separator = "***" } } };
    const out = try buildPrompt(testing.allocator, ctx, &.{}, shape);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("***\nRita: one\n***\nRita: two\nRita:", out);
}

test "buildPrompt places chat_start between the examples and the history" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver." };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "Hi.", .role = .user }};
    const shape = Shape{ .tpl = .{ .context = .{ .story_string = templates.default_story_string, .chat_start = "***" } } };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("A diver.\n***\nJamie: Hi.\nRita:", out);
}

test "selectWindow keeps the newest suffix that fits the budget" {
    const h = [_]PromptMsg{
        .{ .name = "A", .mes = "xx" },
        .{ .name = "A", .mes = "xx" },
        .{ .name = "A", .mes = "xx" },
        .{ .name = "A", .mes = "xx" },
        .{ .name = "A", .mes = "xx" },
    };
    const off = templates.Instruct{ .enabled = false };
    try testing.expectEqual(@as(usize, 3), selectWindow(&h, 18, off).len);
    try testing.expectEqual(@as(usize, 2), selectWindow(&h, 17, off).len);
    try testing.expectEqual(@as(usize, 5), selectWindow(&h, 1000, off).len);
    try testing.expectEqualStrings(h[2].mes, selectWindow(&h, 18, off)[0].mes);
}

test "selectWindow keeps at least the newest message under a tiny budget" {
    const h = [_]PromptMsg{
        .{ .name = "Old", .mes = "gone" },
        .{ .name = "New", .mes = "kept" },
    };
    const off = templates.Instruct{ .enabled = false };
    const w = selectWindow(&h, 0, off);
    try testing.expectEqual(@as(usize, 1), w.len);
    try testing.expectEqualStrings("New", w[0].name);
    try testing.expectEqual(@as(usize, 0), selectWindow(&.{}, 100, off).len);
}

test "selectWindow charges a templated turn its wrapped cost not the bare line" {
    const h = [_]PromptMsg{
        .{ .name = "A", .mes = "xx", .role = .user },
        .{ .name = "A", .mes = "xx", .role = .user },
        .{ .name = "A", .mes = "xx", .role = .user },
    };
    const off = templates.Instruct{ .enabled = false };
    // Untemplated each turn is 6 bytes, so 18 fits all three.
    try testing.expectEqual(@as(usize, 3), selectWindow(&h, 18, off).len);
    // ChatML each turn is 30, so the SAME budget fits one. The old fixed cost kept all three and
    // shipped 90 bytes into an 18-byte budget: a 5x over-fill the backend would truncate.
    try testing.expectEqual(@as(usize, 30), templates.wrapCost(chatml, .user, "A", "xx"));
    try testing.expectEqual(@as(usize, 1), selectWindow(&h, 18, chatml).len);
}

test "buildPromptBudgeted trims history oldest-first but keeps the card block" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver." };
    const history = [_]PromptMsg{
        .{ .name = "Rita", .mes = "oldest line here" },
        .{ .name = "Jamie", .mes = "middle line here" },
        .{ .name = "Rita", .mes = "newest line here" },
    };
    const out = try buildPromptBudgeted(testing.allocator, ctx, &history, "A diver.\n".len + 24, .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "A diver.\n"));
    try testing.expect(std.mem.indexOf(u8, out, "newest line here") != null);
    try testing.expect(std.mem.indexOf(u8, out, "oldest line here") == null);
    try testing.expect(std.mem.endsWith(u8, out, "Rita:"));
}

test "promptCharBudget reserves the response and applies the char ratio" {
    const base = Connection{ .api_type = "", .api_server = "", .max_context = 8192, .max_tokens = 512, .temperature = 0, .top_p = 0, .top_k = 0, .min_p = 0, .rep_pen = 0 };
    try testing.expectEqual(@as(usize, (8192 - 512) * 7 / 2), promptCharBudget(base));
    const unset = Connection{ .api_type = "", .api_server = "", .max_context = 0, .max_tokens = 0, .temperature = 0, .top_p = 0, .top_k = 0, .min_p = 0, .rep_pen = 0 };
    try testing.expectEqual(@as(usize, 8192 * 7 / 2), promptCharBudget(unset));
}

test "an in_chat note lands at its depth in the history" {
    const ctx = Ctx{ .char = "Rita" };
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "one", .role = .user },
        .{ .name = "Rita", .mes = "two", .role = .assistant },
        .{ .name = "Jamie", .mes = "three", .role = .user },
    };
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = "" } },
        .note = .{ .prompt = "It is raining.", .interval = 1, .position = .in_chat, .depth = 1, .role = .system },
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Jamie: one\nRita: two\n: It is raining.\nJamie: three\nRita:", out);
}

test "an in_chat note at depth zero lands after the newest turn" {
    const ctx = Ctx{ .char = "Rita" };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "one", .role = .user }};
    const shape = Shape{
        .tpl = .{ .instruct = chatml, .context = .{ .story_string = "" } },
        .note = .{ .prompt = "Be terse.", .interval = 1, .position = .in_chat, .depth = 0, .role = .system },
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    const want =
        "<|im_start|>user\none<|im_end|>\n" ++
        "<|im_start|>system\nBe terse.<|im_end|>\n" ++
        "<|im_start|>assistant\n";
    try testing.expectEqualStrings(want, out);
}

test "the anchor positions ride the story string instead of the history" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .anchor_before = "BEFORE", .anchor_after = "AFTER" };
    const story = "{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}{{#if anchorAfter}}{{anchorAfter}}\n{{/if}}";
    const shape = Shape{ .tpl = .{ .context = .{ .story_string = story } } };
    const out = try buildPrompt(testing.allocator, ctx, &.{}, shape);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("BEFORE\nA diver.\nAFTER\nRita:", out);
}

test "a note is never trimmed away by a tight budget" {
    // The note is a control instruction, not history: it is reserved before the walk.
    const ctx = Ctx{ .char = "Rita" };
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "an old line", .role = .user },
        .{ .name = "Rita", .mes = "a new line", .role = .assistant },
    };
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = "" } },
        .note = .{ .prompt = "Keep it short.", .interval = 1, .position = .in_chat, .depth = 0, .role = .system },
    };
    const out = try buildPromptBudgeted(testing.allocator, ctx, &history, 20, shape);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Keep it short.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "an old line") == null);
    try testing.expect(std.mem.indexOf(u8, out, "a new line") != null);
}

test "an inactive note reaches the prompt nowhere" {
    const ctx = Ctx{ .char = "Rita" };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "one", .role = .user }};
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = "" } },
        .note = .{ .prompt = "  ", .interval = 1, .position = .in_chat, .depth = 0 },
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Jamie: one\nRita:", out);
}

test "a periodic note only fires on its interval" {
    const ctx = Ctx{ .char = "Rita" };
    const two = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "one", .role = .user },
        .{ .name = "Rita", .mes = "two", .role = .assistant },
    };
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = "" } },
        .note = .{ .prompt = "N", .interval = 2, .position = .in_chat, .depth = 0, .role = .system },
    };
    const fires = try buildPrompt(testing.allocator, ctx, &two, shape);
    defer testing.allocator.free(fires);
    try testing.expect(std.mem.indexOf(u8, fires, "N") != null);

    const one = [_]PromptMsg{.{ .name = "Jamie", .mes = "one", .role = .user }};
    const quiet = try buildPrompt(testing.allocator, ctx, &one, shape);
    defer testing.allocator.free(quiet);
    try testing.expect(std.mem.indexOf(u8, quiet, ": N") == null);
}

test "buildPromptBudgeted cleans up on every allocation failure" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .system = "You are {{char}}." };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, c: Ctx) !void {
            const history = [_]PromptMsg{
                .{ .name = "Jamie", .mes = "Hi.", .role = .user },
                .{ .name = "Rita", .mes = "Hello.", .role = .assistant },
            };
            const shape = Shape{
                .tpl = .{ .instruct = chatml, .context = .{ .story_string = templates.default_story_string, .example_separator = "***" } },
                .note = .{ .prompt = "Be terse.", .interval = 1, .position = .in_chat, .depth = 1, .role = .system },
            };
            const out = try buildPromptBudgeted(alloc, c, &history, 4096, shape);
            alloc.free(out);
        }
    }.run, .{ctx});
}

test "stopSequences carries the template stop or nothing at all" {
    var buf: [1][]const u8 = undefined;
    const stop = stopSequences(chatml, &buf);
    try testing.expectEqual(@as(usize, 1), stop.len);
    try testing.expectEqualStrings("<|im_end|>", stop[0]);

    try testing.expectEqual(@as(usize, 0), stopSequences(.{ .enabled = false, .stop_sequence = "<|im_end|>" }, &buf).len);
    try testing.expectEqual(@as(usize, 0), stopSequences(.{ .enabled = true, .stop_sequence = "" }, &buf).len);
}

test "buildRequestBody carries the connection, prompt, and stream flag" {
    const conn = Connection{
        .api_type = try testing.allocator.dupe(u8, "llamacpp"),
        .api_server = try testing.allocator.dupe(u8, "http://127.0.0.1:8080"),
        .max_context = 8192,
        .max_tokens = 256,
        .temperature = 0.8,
        .top_p = 0.95,
        .top_k = 40,
        .min_p = 0.05,
        .rep_pen = 1.1,
    };
    defer freeConnection(testing.allocator, conn);
    const body = try buildRequestBody(testing.allocator, conn, "Rita:", &.{});
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("Rita:", o.get("prompt").?.string);
    try testing.expectEqualStrings("llamacpp", o.get("api_type").?.string);
    try testing.expectEqualStrings("http://127.0.0.1:8080", o.get("api_server").?.string);
    try testing.expectEqual(true, o.get("stream").?.bool);
    try testing.expectEqual(@as(i64, 256), o.get("max_new_tokens").?.integer);
    try testing.expectEqual(@as(i64, 256), o.get("max_tokens").?.integer);
    try testing.expectEqual(@as(f64, 0.8), o.get("temperature").?.float);
    try testing.expectEqual(@as(usize, 0), o.get("stop").?.array.items.len);
}

test "buildRequestBody carries the stop sequence under both backend spellings" {
    // The tear: with no stop field the model runs past <|im_end|> and writes the user's next line.
    const conn = Connection{
        .api_type = try testing.allocator.dupe(u8, "llamacpp"),
        .api_server = try testing.allocator.dupe(u8, "http://x"),
        .max_context = 8192,
        .max_tokens = 256,
        .temperature = 0.8,
        .top_p = 1,
        .top_k = 0,
        .min_p = 0,
        .rep_pen = 1,
    };
    defer freeConnection(testing.allocator, conn);
    var buf: [1][]const u8 = undefined;
    const body = try buildRequestBody(testing.allocator, conn, "p", stopSequences(chatml, &buf));
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("<|im_end|>", o.get("stop").?.array.items[0].string);
    try testing.expectEqualStrings("<|im_end|>", o.get("stopping_strings").?.array.items[0].string);
}
