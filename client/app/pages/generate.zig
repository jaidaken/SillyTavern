//! Pure prompt assembly, macro resolver, and text-completion request-body builder for the send
//! loop. No zx import, so this whole module runs under `zig build test` (ZX5 split); char_api.zig
//! (impure) fetches the settings blob, the deep card, and the persona, then calls in, and the SSE
//! pump stays in the JS glue (ZX16).
//!
//! Scope this phase: the textgen family only (main_api == "textgenerationwebui"). The openai-chat
//! and kobold-horde families use other endpoints and body shapes and are out of scope; extraction
//! returns error.UnsupportedApi for them rather than guessing.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The backend connection pulled out of the settings blob. `api_type`/`api_server` are owned; the
/// samplers are plain scalars coerced from the blob with backend-neutral defaults when a field is
/// absent. Free with `freeConnection`.
pub const Connection = struct {
    api_type: []u8,
    api_server: []u8,
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

/// The values the card/persona macros resolve to. Everything is borrowed; the caller (char_api)
/// keeps the backing strings alive across the assembly call.
pub const Ctx = struct {
    char: []const u8 = "",
    user: []const u8 = "",
    persona: []const u8 = "",
    description: []const u8 = "",
    personality: []const u8 = "",
    scenario: []const u8 = "",
    mes_example: []const u8 = "",
};

/// The resolvable macro name -> value, or null for a name this narrow resolver does not know (the
/// caller keeps the literal untouched, so an unknown `{{macro}}` survives rather than blanking).
/// Deliberately NOT the STscript engine: the pure card/persona set plus `{{newline}}`. Dynamic
/// macros (time/date/roll) are impure and intentionally excluded this phase.
fn resolve(name: []const u8, ctx: Ctx) ?[]const u8 {
    if (std.mem.eql(u8, name, "char")) return ctx.char;
    if (std.mem.eql(u8, name, "user")) return ctx.user;
    if (std.mem.eql(u8, name, "persona")) return ctx.persona;
    if (std.mem.eql(u8, name, "description")) return ctx.description;
    if (std.mem.eql(u8, name, "personality")) return ctx.personality;
    if (std.mem.eql(u8, name, "scenario")) return ctx.scenario;
    if (std.mem.eql(u8, name, "mesExamples")) return ctx.mes_example;
    if (std.mem.eql(u8, name, "newline")) return "\n";
    return null;
}

/// Substitutes every known `{{macro}}` in `text` in one pass. An unknown macro is left verbatim, an
/// unterminated `{{` is copied through, and a `name:args` form resolves on the bare name (args are
/// ignored this phase). Owned result.
pub fn substituteMacros(alloc: Allocator, text: []const u8, ctx: Ctx) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '{' and text[i + 1] == '{') {
            if (std.mem.indexOfPos(u8, text, i + 2, "}}")) |close| {
                const inner = std.mem.trim(u8, text[i + 2 .. close], " \t");
                const bare = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, inner, ':')) |c| inner[0..c] else inner, " \t");
                if (resolve(bare, ctx)) |val| {
                    try out.appendSlice(alloc, val);
                } else {
                    try out.appendSlice(alloc, text[i .. close + 2]);
                }
                i = close + 2;
                continue;
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// One history turn for the prompt: the sender's display name and the message text.
pub const PromptMsg = struct {
    name: []const u8,
    mes: []const u8,
};

/// Builds the minimal text-completion prompt: the card's description, personality, and scenario
/// (each macro-substituted), then the example dialogue, then the chat history as `Name: mes` lines,
/// then the character-name prefix that primes the model to continue in character. `history` is the
/// caller's choice of source: it is passed in, not read from a fixed store, so the token-budgeted
/// full-history window (J1) can swap the source without touching this function (invariant 2). Owned
/// result.
pub fn buildPrompt(alloc: Allocator, ctx: Ctx, history: []const PromptMsg) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try appendField(alloc, &out, ctx, ctx.description, "");
    try appendField(alloc, &out, ctx, ctx.personality, "");
    try appendField(alloc, &out, ctx, ctx.scenario, "Scenario: ");
    try appendField(alloc, &out, ctx, ctx.mes_example, "");

    for (history) |m| {
        try out.appendSlice(alloc, m.name);
        try out.appendSlice(alloc, ": ");
        try out.appendSlice(alloc, m.mes);
        try out.append(alloc, '\n');
    }

    try out.appendSlice(alloc, ctx.char);
    try out.append(alloc, ':');
    return out.toOwnedSlice(alloc);
}

fn appendField(alloc: Allocator, out: *std.ArrayList(u8), ctx: Ctx, raw: []const u8, prefix: []const u8) Allocator.Error!void {
    if (raw.len == 0) return;
    const subbed = try substituteMacros(alloc, raw, ctx);
    defer alloc.free(subbed);
    if (std.mem.trim(u8, subbed, " \t\r\n").len == 0) return;
    try out.appendSlice(alloc, prefix);
    try out.appendSlice(alloc, subbed);
    try out.append(alloc, '\n');
}

/// Builds the JSON body for POST /api/backends/text-completions/generate. `stream` is always true:
/// the send loop reads the model SSE the server pipes back unchanged. The samplers ride from the
/// connection; the server filters them per backend type. Owned result.
pub fn buildRequestBody(alloc: Allocator, conn: Connection, prompt: []const u8) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .prompt = prompt,
        .max_new_tokens = conn.max_tokens,
        .max_tokens = conn.max_tokens,
        .stream = true,
        .api_type = conn.api_type,
        .api_server = conn.api_server,
        .temperature = conn.temperature,
        .top_p = conn.top_p,
        .top_k = conn.top_k,
        .min_p = conn.min_p,
        .rep_pen = conn.rep_pen,
        .repetition_penalty = conn.rep_pen,
    }, .{});
}

const testing = std.testing;

test "extractConnection reads type, server_urls, and coerced samplers" {
    const settings =
        \\{"main_api":"textgenerationwebui","amount_gen":320,
        \\ "textgenerationwebui_settings":{"type":"llamacpp",
        \\   "server_urls":{"llamacpp":"http://127.0.0.1:8080","ooba":"http://x"},
        \\   "temp":0.8,"top_p":0.95,"top_k":40,"min_p":0.05,"rep_pen":1.1}}
    ;
    const conn = try extractConnection(testing.allocator, settings);
    defer freeConnection(testing.allocator, conn);
    try testing.expectEqualStrings("llamacpp", conn.api_type);
    try testing.expectEqualStrings("http://127.0.0.1:8080", conn.api_server);
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

test "substituteMacros resolves the card and persona set every occurrence" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie", .persona = "a diver", .description = "d", .personality = "warm", .scenario = "a wreck", .mes_example = "ex" };
    const out = try substituteMacros(testing.allocator, "{{char}} to {{user}} ({{persona}}); {{char}} waits.{{newline}}end", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita to Jamie (a diver); Rita waits.\nend", out);
}

test "substituteMacros keeps an unknown macro and a dangling brace verbatim" {
    const ctx = Ctx{ .char = "Rita" };
    const out = try substituteMacros(testing.allocator, "{{char}} {{roll:2}} {{unknown}} {{oops", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita {{roll:2}} {{unknown}} {{oops", out);
}

test "substituteMacros cleans up on every allocation failure" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie" };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, c: Ctx) !void {
            const out = try substituteMacros(alloc, "{{char}} meets {{user}}{{newline}}", c);
            alloc.free(out);
        }
    }.run, .{ctx});
}

test "buildPrompt assembles system block, history, and the char prefix" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie", .description = "{{char}} is a diver.", .personality = "warm", .scenario = "the shoals", .mes_example = "" };
    const history = [_]PromptMsg{
        .{ .name = "Rita", .mes = "The lantern gutters." },
        .{ .name = "Jamie", .mes = "What is that?" },
    };
    const out = try buildPrompt(testing.allocator, ctx, &history);
    defer testing.allocator.free(out);
    const want =
        "Rita is a diver.\n" ++
        "warm\n" ++
        "Scenario: the shoals\n" ++
        "Rita: The lantern gutters.\n" ++
        "Jamie: What is that?\n" ++
        "Rita:";
    try testing.expectEqualStrings(want, out);
}

test "buildPrompt omits empty card fields and still primes the char" {
    const ctx = Ctx{ .char = "Rita", .description = "", .personality = "", .scenario = "", .mes_example = "" };
    const out = try buildPrompt(testing.allocator, ctx, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Rita:", out);
}

test "buildRequestBody carries the connection, prompt, and stream flag" {
    const conn = Connection{
        .api_type = try testing.allocator.dupe(u8, "llamacpp"),
        .api_server = try testing.allocator.dupe(u8, "http://127.0.0.1:8080"),
        .max_tokens = 256,
        .temperature = 0.8,
        .top_p = 0.95,
        .top_k = 40,
        .min_p = 0.05,
        .rep_pen = 1.1,
    };
    defer freeConnection(testing.allocator, conn);
    const body = try buildRequestBody(testing.allocator, conn, "Rita:");
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
}
