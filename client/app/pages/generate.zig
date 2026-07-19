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
const wi_engine = @import("./world_info_engine.zig");

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
    /// The user-configured model name (stock getTextGenModel: the per-type `*_model` field). Owned,
    /// possibly empty when the backend carries none (koboldcpp, or an unset field); the tokenizer
    /// resolver then defers to the probed model and finally the llama default. Feeds getTokenizerBestMatch.
    model: []u8,
    /// Stock power_user.token_padding (default 64): tokens the classic client reserves out of the history
    /// budget (getMessagesTokenCount adds it to the overhead seed, tokenizers.js:482). promptTokenBudget
    /// subtracts it so the trim boundary matches.
    token_padding: i64,
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
    alloc.free(conn.model);
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
    const model = try alloc.dupe(u8, textGenModel(tg, type_str));
    errdefer alloc.free(model);

    return .{
        .api_type = api_type,
        .api_server = api_server,
        .model = model,
        .token_padding = tokenPadding(root),
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

/// The configured model name for this backend, mirroring the classic getTextGenModel
/// (textgen-settings.js:1479): ooba reads `custom_model`, huggingface is the fixed "tgi", koboldcpp
/// carries none, and the rest read `<type>_model` (llamacpp_model, vllm_model, ...). Borrowed from the
/// blob. Empty means the caller defers to the connection probe's reported model.
fn textGenModel(tg: std.json.ObjectMap, type_str: []const u8) []const u8 {
    if (std.mem.eql(u8, type_str, "huggingface")) return "tgi";
    if (std.mem.eql(u8, type_str, "ooba")) return strField(tg, "custom_model");
    if (std.mem.eql(u8, type_str, "koboldcpp")) return "";
    var buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}_model", .{type_str}) catch return "";
    return strField(tg, key);
}

/// Stock power_user.token_padding (default 64), read from the settings blob's power_user object. A
/// missing or non-object power_user, or an absent field, yields the classic default.
fn tokenPadding(root: std.json.ObjectMap) i64 {
    const pu = switch (root.get("power_user") orelse return 64) {
        .object => |o| o,
        else => return 64,
    };
    return numI64(pu, "token_padding", 64);
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
    const hist_tokens = budgetTokens(conn);
    return (hist_tokens *| TOKEN_CHARS_NUM) / TOKEN_CHARS_DEN;
}

/// The history token budget shared by both budgets: context minus the response reserve minus the stock
/// token_padding the classic client holds back (getMessagesTokenCount seeds the count with it). A
/// missing or non-positive context falls back to the classic 8192 default.
fn budgetTokens(conn: Connection) usize {
    const ctx_tokens: usize = if (conn.max_context > 0) @intCast(conn.max_context) else 8192;
    const resp_tokens: usize = if (conn.max_tokens > 0) @intCast(conn.max_tokens) else 0;
    const padding: usize = if (conn.token_padding > 0) @intCast(conn.token_padding) else 0;
    return ctx_tokens -| resp_tokens -| padding;
}

/// Everything about prompt SHAPE that is not the card content or the history: the instruct/context
/// templates the formatting panel edits, the chat's author's note, and the world-info activation
/// inputs (probe#3 delta 1). Defaulted, so a caller that has none still assembles the classic
/// `Name: mes` prompt.
pub const Shape = struct {
    tpl: Templates = .{},
    note: Note = .{},
    /// The character's own depth note (stock "character-specific A/N", data.extensions.depth_prompt):
    /// always in_chat, its own depth + role. Empty prompt = absent.
    char_note: Note = .{},
    /// The jailbreak / post-history instruction, pre-resolved (its {{original}} is the global
    /// post_history, resolved at composition). Injected as a user turn after the history (depth 0).
    jailbreak: []const u8 = "",
    /// World-info candidates in priority order (WorldInfoStore.collectActive); store-owned memory,
    /// borrowed for the build only.
    wi_entries: []const wi_engine.Entry = &.{},
    /// Stock world_info_depth: how many newest PROMPT-window messages the key scan reads.
    wi_scan_depth: usize = 2,
    /// Engine-side cap on the WI slice alone (probe#3 delta 2); the story string stays uncapped.
    wi_budget_chars: usize = std.math.maxInt(usize),
    /// Stock world_info_recursive: activated content re-enters the key scan.
    wi_recursive: bool = false,
    /// Stock world_info_case_sensitive: default for a null per-entry caseSensitive.
    wi_case_sensitive: bool = false,
    /// Stock world_info_match_whole_words: default for a null per-entry matchWholeWords.
    wi_match_whole_words: bool = false,
    /// Stock world_info_min_activations: keep widening the scan window until this many entries fire.
    wi_min_activations: usize = 0,
    /// Stock world_info_min_activations_depth_max: hard cap on the widened depth (0 = history-bounded).
    wi_min_activations_depth_max: usize = 0,
    /// Stock world_info_use_group_scoring: default for a null per-entry useGroupScoring.
    wi_use_group_scoring: bool = false,
    /// Caller-supplied roll for probability entries (probe#3 delta 5); null = every roll passes.
    wi_rng: ?std.Random = null,
    /// The chat's persisted timed-effect state (stock chat_metadata.timedWorldInfo) at scan start.
    /// The updated state is surfaced through buildPromptBudgeted's timed_out_json out-param.
    wi_timed_in: wi_engine.TimedState = .{},
    /// Chunk-4 characterFilter: the selected character's avatar filename (stock getCharaFilename).
    wi_chara_filename: []const u8 = "",
    /// Chunk-4 characterFilter tags: the character's tag IDs, or null when it has no tag mapping.
    wi_char_tags: ?[]const []const u8 = null,
    /// Chunk-4 generation-type triggers: the current generation type (stock globalScanData.trigger).
    wi_generation_trigger: []const u8 = "normal",
    /// Chunk-4 extended scan sources: extra text an entry may scan for its keys, gated per-entry.
    wi_persona_description: []const u8 = "",
    wi_character_description: []const u8 = "",
    wi_character_personality: []const u8 = "",
    wi_character_depth_prompt: []const u8 = "",
    wi_scenario: []const u8 = "",
    wi_creator_notes: []const u8 = "",
    /// Stock power_user.persona_description_position: which of the five placements the persona takes.
    /// The persona TEXT is `ctx.persona`; the story slot fills only for IN_PROMPT / AFTER_CHAR, and
    /// AT_DEPTH injects the same text in-chat. TOP_AN / BOTTOM_AN are joined into the note upstream.
    persona_position: templates.PersonaPosition = .in_prompt,
    /// Stock power_user.persona_description_depth / _role for the AT_DEPTH placement (2 / 0). Role is
    /// an extension_prompt_roles int (0 system, 1 user, 2 assistant).
    persona_depth: i64 = templates.persona_default_depth,
    persona_role: i64 = templates.persona_default_role,
};

/// Builds the text-completion prompt with no budget cap. Owned result.
pub fn buildPrompt(alloc: Allocator, ctx: Ctx, history: []const PromptMsg, shape: Shape) Allocator.Error![]u8 {
    return buildPromptBudgeted(alloc, ctx, history, std.math.maxInt(usize), shape, null);
}

/// The prompt, in the order the classic client assembles it:
///   1. the story string (system, world-info, card fields, persona, author's-note anchors), wrapped
///      in the instruct template's story-string sequences
///   2. the example dialogue, each block under the context template's example separator
///   3. `chat_start`
///   4. the chat history, each turn wrapped in the sequence its ROLE selects, trimmed oldest-first
///      to the remaining budget
///   5. the in-chat injections at their depths AFTER the trim: the `in_chat` author's note and the
///      activated world-info atDepth groups
///   6. the continuation prefix that primes the model to answer
///
/// World info activates first (scan over the full window at wi_scan_depth, capped by its own
/// wi_budget_chars) and rides the story string's wi slots, the example section, the note anchors,
/// or the injection list per entry position. The system block is built in full first (it is
/// per-card and small) and the injections are reserved out of the budget BEFORE the history walk,
/// so neither can be silently trimmed: they are control instructions, and losing one would change
/// the reply with nothing to point at. The remaining budget bounds the history alone. Owned result.
/// `timed_out_json`, when non-null, receives the updated timed-effect state (stock
/// chat_metadata.timedWorldInfo) as an owned JSON string the caller persists then frees. It is the
/// last thing set, so an error anywhere leaves it untouched and the caller frees nothing.
pub fn buildPromptBudgeted(alloc: Allocator, ctx: Ctx, history: []const PromptMsg, budget_chars: usize, shape: Shape, timed_out_json: ?*[]const u8) Allocator.Error![]u8 {
    var pieces = try assemblePieces(alloc, ctx, history, shape, timed_out_json != null);
    defer freePieces(alloc, &pieces);

    // The all-in-one / fallback path: cost every piece at its BYTE length. wrapMessage's length equals
    // the wrapCost the pre-token walk charged, and the overhead byte length equals the old accumulator
    // size, so this reproduces the char-budget trim boundary byte-for-byte. The real token path lives
    // in char_api, which tokenizes each piece and calls fitAndAssemble with a token budget instead.
    const costs = try byteCostTable(alloc, pieces);
    defer freeCostTable(alloc, costs);
    const result = try fitAndAssemble(alloc, pieces, costs, budget_chars);
    errdefer alloc.free(result);
    if (timed_out_json) |slot| {
        slot.* = pieces.timed_json.?;
        pieces.timed_json = null; // ownership moves to the caller's slot; freePieces must not touch it
    }
    return result;
}

/// One in-chat control turn, already grouped and wrapped at assembly time so its token cost is measured
/// alone. `depth` counts back from the newest windowed turn; `rank` sets the emit order at a shared
/// depth (stock doChatInject: ASSISTANT, USER, SYSTEM, then the post-history jailbreak).
pub const AssembledInjection = struct {
    depth: usize,
    rank: u8,
    wrapped: []u8,
};

/// A single depth-injection source before grouping: RAW (unsubstituted) text with its target
/// depth+role. Contributions at the same depth+role are trimmed, joined, and substituted as one block
/// in groupInjections, then wrapped into one AssembledInjection (stock getExtensionPrompt).
const Contribution = struct {
    depth: usize,
    role: templates.Role,
    text: []u8,
};

/// Stock extension_prompt_roles int (0 system, 1 user, 2 assistant) to a template role.
fn roleFromInt(v: i64) templates.Role {
    return switch (v) {
        1 => .user,
        2 => .assistant,
        else => .system,
    };
}

/// Emit rank at a shared depth: stock doChatInject pushes [SYSTEM, USER, ASSISTANT] into a reversed
/// array, so the final order is ASSISTANT, USER, SYSTEM; the jailbreak (post-history) trails them all.
fn roleRank(role: templates.Role) u8 {
    return switch (role) {
        .assistant => 0,
        .user => 1,
        .system => 2,
    };
}

const jailbreak_rank: u8 = 3;

/// Groups depth-injection contributions to match stock doChatInject (script.js:5599) + getExtensionPrompt
/// (script.js:3286): all contributions at one depth+role become ONE turn (each value trimmed, joined by
/// '\n', then leading whitespace stripped), wrapped once. Contributions arrive in stock key order
/// (2_floating_prompt < DEPTH_PROMPT < PERSONA_DESCRIPTION < customDepthWI), so join order needs no sort.
fn groupInjections(alloc: Allocator, out: *std.ArrayList(AssembledInjection), instruct: templates.Instruct, contribs: []const Contribution, mctx: Ctx) Allocator.Error!void {
    for (contribs, 0..) |c, ci| {
        var owns = true;
        for (contribs[0..ci]) |p| {
            if (p.depth == c.depth and p.role == c.role) {
                owns = false;
                break;
            }
        }
        if (!owns) continue;

        // Stock getExtensionPrompt trims each RAW value then joins with '\n' (script.js:3286).
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(alloc);
        var any = false;
        for (contribs) |m| {
            if (m.depth != c.depth or m.role != c.role or m.text.len == 0) continue;
            if (any) try joined.append(alloc, '\n');
            try joined.appendSlice(alloc, std.mem.trim(u8, m.text, &std.ascii.whitespace));
            any = true;
        }
        if (!any) continue;

        // substituteParams runs ONCE over the JOINED block (script.js:3294), so a {{pick}} seeds off
        // that block; doChatInject then trimStarts the result (script.js:5618).
        const subbed = try substituteMacros(alloc, joined.items, mctx);
        defer alloc.free(subbed);
        const value = std.mem.trimStart(u8, subbed, &std.ascii.whitespace);
        if (value.len == 0) continue;
        const name = switch (c.role) {
            .user => mctx.user,
            .assistant => mctx.char,
            .system => "",
        };
        const wrapped = try templates.wrapMessage(alloc, instruct, c.role, name, value);
        errdefer alloc.free(wrapped);
        try out.append(alloc, .{ .depth = c.depth, .rank = roleRank(c.role), .wrapped = wrapped });
    }
}

/// Everything the prompt is made of, as separately-owned strings whose token cost the caller measures
/// one by one (matching the classic client, which counts each formatMessageHistoryItem and the story
/// overhead independently). `assemblePieces` produces it; `fitAndAssemble` walks the budget and joins.
/// All fields are allocator-owned and survive an async token-count round-trip; free with `freePieces`.
pub const Pieces = struct {
    /// The story block plus example dialogue plus chat_start: the fixed prompt prefix before history.
    overhead: []u8,
    injections: []AssembledInjection,
    /// One pre-wrapped string per input history turn, in input order.
    wrapped_history: [][]u8,
    prefix: []u8,
    history_len: usize,
    /// power_user.collapse_newlines: fitAndAssemble collapses the joined prompt's newline runs to one
    /// (script.js:5171). A scalar, so freePieces ignores it.
    collapse_newlines: bool,
    /// The updated timed-effect state as owned JSON, or null when the caller did not ask for it.
    timed_json: ?[]const u8,
};

pub fn freePieces(alloc: Allocator, p: *Pieces) void {
    alloc.free(p.overhead);
    for (p.injections) |inj| alloc.free(inj.wrapped);
    alloc.free(p.injections);
    for (p.wrapped_history) |w| alloc.free(w);
    alloc.free(p.wrapped_history);
    alloc.free(p.prefix);
    if (p.timed_json) |j| alloc.free(j);
}

/// Per-piece costs the budget walk sums, in whatever unit the caller measured (bytes for the fallback,
/// real tokens for the send path). Parallel to `Pieces.injections` and `Pieces.wrapped_history`.
pub const CostTable = struct {
    overhead: usize,
    injections: []const usize,
    history: []const usize,
};

/// The prompt's token budget: context size minus the response reserve minus token_padding, matching the
/// classic effective history budget (this_max_context = max_context - amount_gen, with token_padding
/// held back in the seed). The send path passes this to fitAndAssemble alongside real per-piece counts.
pub fn promptTokenBudget(conn: Connection) usize {
    return budgetTokens(conn);
}

/// A cost table where each piece is charged its BYTE length: the fallback / char-budget path, and the
/// unit the pre-token builder used (wrapMessage length == wrapCost). Free with freeCostTable.
pub fn byteCostTable(alloc: Allocator, pieces: Pieces) Allocator.Error!CostTable {
    const inj = try alloc.alloc(usize, pieces.injections.len);
    errdefer alloc.free(inj);
    for (pieces.injections, 0..) |x, i| inj[i] = x.wrapped.len;
    const his = try alloc.alloc(usize, pieces.wrapped_history.len);
    for (pieces.wrapped_history, 0..) |w, i| his[i] = w.len;
    return .{ .overhead = pieces.overhead.len, .injections = inj, .history = his };
}

pub fn freeCostTable(alloc: Allocator, c: CostTable) void {
    alloc.free(c.injections);
    alloc.free(c.history);
}

/// The newest suffix of history whose cumulative cost stays strictly under `budget`, as a START index
/// into the cost array. Walks oldest-first from the tail so the freshest turns survive a tight budget.
/// A turn is kept only if it fits (classic `tokenCount < this_max_context`, script.js:4891): the newest
/// turn is NOT forced, so an overhead that alone fills the budget yields an empty history exactly as the
/// classic client does. Cost-unit agnostic (bytes or tokens).
fn fitWindow(costs: []const usize, budget: usize) usize {
    var used: usize = 0;
    var i: usize = costs.len;
    while (i > 0) {
        const cost = costs[i - 1];
        if (used + cost >= budget) break;
        used += cost;
        i -= 1;
    }
    return i;
}

fn injectionLess(injections: []const AssembledInjection, a: usize, b: usize) bool {
    const ia = injections[a];
    const ib = injections[b];
    if (ia.depth != ib.depth) return ia.depth > ib.depth;
    return ia.rank < ib.rank;
}

fn appendAssembledInjectionsAt(alloc: Allocator, out: *std.ArrayList(u8), injections: []const AssembledInjection, window_len: usize, at: usize) Allocator.Error!void {
    // Injections clamped to the head (depth past the window) keep depth order (deeper first, stock inserts
    // them oldest); within one depth the role groups run ASSISTANT, USER, SYSTEM, then the jailbreak.
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(alloc);
    for (injections, 0..) |inj, idx| {
        if (window_len -| inj.depth != at) continue;
        try order.append(alloc, idx);
    }
    std.sort.pdq(usize, order.items, injections, injectionLess);
    for (order.items) |idx| try out.appendSlice(alloc, injections[idx].wrapped);
}

/// Joins the assembled pieces under `costs` against `budget`: reserves the overhead and every injection
/// out of the budget, trims history oldest-first over what remains, then emits overhead, the surviving
/// history with each injection at its depth, and the continuation prefix. Every CR is stripped last
/// (script.js:5075). The injections are reserved before the history walk, so a tight budget sheds
/// history, never a control instruction. Owned result.
pub fn fitAndAssemble(alloc: Allocator, pieces: Pieces, costs: CostTable, budget: usize) Allocator.Error![]u8 {
    var inj_sum: usize = 0;
    for (costs.injections) |c| inj_sum += c;
    const start = fitWindow(costs.history, budget -| costs.overhead -| inj_sum);
    const window_len = pieces.history_len - start;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, pieces.overhead);
    var i: usize = 0;
    while (i < window_len) : (i += 1) {
        try appendAssembledInjectionsAt(alloc, &out, pieces.injections, window_len, i);
        try out.appendSlice(alloc, pieces.wrapped_history[start + i]);
    }
    try appendAssembledInjectionsAt(alloc, &out, pieces.injections, window_len, window_len);
    // Classic modifyLastPromptLine adds the cue only for a non-empty windowed history (script.js:4994):
    // a real history trimmed away entirely ships none; a no-history caller still primes the char.
    if (window_len > 0 or pieces.history_len == 0) try out.appendSlice(alloc, pieces.prefix);

    // Stock strips every CR from the assembled prompt (script.js:5075, .replace(/\r/gm, '')); card
    // fields routinely carry CRLF and the wire prompt is LF-only. Position-independent, so stripping the
    // joined buffer once equals stripping each piece, which is what the token counter does per piece.
    var w: usize = 0;
    for (out.items) |b| {
        if (b == '\r') continue;
        out.items[w] = b;
        w += 1;
    }
    out.shrinkRetainingCapacity(w);

    // Stock's collapseNewlines on the final combined prompt (script.js:5171): every run of newlines
    // becomes one. Runs AFTER the CR strip, matching stock's 5075-then-5171 order. Position-independent.
    if (pieces.collapse_newlines) {
        var cw: usize = 0;
        var prev_nl = false;
        for (out.items) |b| {
            if (b == '\n' and prev_nl) continue;
            prev_nl = b == '\n';
            out.items[cw] = b;
            cw += 1;
        }
        out.shrinkRetainingCapacity(cw);
    }
    return out.toOwnedSlice(alloc);
}

/// Assembles the prompt into separately-costable pieces WITHOUT applying the budget: the story-block
/// overhead, each in-chat injection pre-wrapped, and each history turn pre-wrapped. World info activates
/// here (it feeds the story string and the injections), and the timed-effect state is stringified while
/// its arena is still alive when `want_timed`. The caller measures each piece and calls fitAndAssemble.
pub fn assemblePieces(alloc: Allocator, ctx: Ctx, history: []const PromptMsg, shape: Shape, want_timed: bool) Allocator.Error!Pieces {
    // The world-info scan reads the PROMPT window tail, so the display window never bounds what
    // can activate (invariant 2).
    const scan_texts = try alloc.alloc([]const u8, history.len);
    defer alloc.free(scan_texts);
    for (history, 0..) |m, i| scan_texts[i] = m.mes;
    var wi_act = try wi_engine.activate(alloc, .{
        .entries = shape.wi_entries,
        .scan_depth = shape.wi_scan_depth,
        .budget_chars = shape.wi_budget_chars,
        .recursive = shape.wi_recursive,
        .case_sensitive = shape.wi_case_sensitive,
        .match_whole_words = shape.wi_match_whole_words,
        .min_activations = shape.wi_min_activations,
        .min_activations_depth_max = shape.wi_min_activations_depth_max,
        .use_group_scoring = shape.wi_use_group_scoring,
        .rng = shape.wi_rng,
        .timed_in = shape.wi_timed_in,
        .chara_filename = shape.wi_chara_filename,
        .char_tags = shape.wi_char_tags,
        .generation_trigger = shape.wi_generation_trigger,
        .persona_description = shape.wi_persona_description,
        .character_description = shape.wi_character_description,
        .character_personality = shape.wi_character_personality,
        .character_depth_prompt = shape.wi_character_depth_prompt,
        .scenario = shape.wi_scenario,
        .creator_notes = shape.wi_creator_notes,
    }, scan_texts);
    defer wi_act.deinit();

    // Probe#3 delta 1: the ctx copy that feeds {{wiBefore}}/{{wiAfter}}; macros inside activated
    // content resolve in renderStoryString's nested pass.
    var wctx = ctx;
    wctx.wi_before = wi_act.before;
    wctx.wi_after = wi_act.after;
    const outlet_map = try alloc.alloc(macros.Outlet, wi_act.outlets.len);
    defer alloc.free(outlet_map);
    for (wi_act.outlets, 0..) |g, i| outlet_map[i] = .{ .name = g.name, .content = g.content };
    wctx.outlets = outlet_map;

    // Stock substitutes macros in the instruct wrap sequences when instruct.macro is on
    // (instruct-mode.js); else an output_sequence "<|im_start|>assistant {{char}}:" ships literal.
    const instruct = try resolveInstructMacros(alloc, shape.tpl.instruct, wctx);
    defer freeInstructMacros(alloc, shape.tpl.instruct, instruct);

    // Stock drops wi content a story string has no slot for, warn-only (power-user.js:2294).
    if ((wi_act.before.len > 0 and !storyHasSlot(shape.tpl.context.story_string, "{{wiBefore}}", "{{loreBefore}}")) or
        (wi_act.after.len > 0 and !storyHasSlot(shape.tpl.context.story_string, "{{wiAfter}}", "{{loreAfter}}")) or
        (wi_act.outlets.len > 0 and std.mem.indexOf(u8, shape.tpl.context.story_string, "{{outlet::") == null))
    {
        std.log.scoped(.wi).warn("the story string has no wi slot; activated world info is dropped", .{});
    }

    // Persona TOP_AN / BOTTOM_AN is the note's OUTERMOST element, outside the WI an-anchors: stock wraps
    // persona around the WI-wrapped note (script.js:3183 after world-info.js:5149), gated on interval firing.
    const persona_an = (shape.persona_position == .top_an or shape.persona_position == .bottom_an) and
        wctx.persona.len > 0 and authors_note.intervalFires(shape.note, history.len);
    const persona_an_top = shape.persona_position == .top_an;
    const persona_an_txt: []const u8 = if (persona_an) wctx.persona else "";

    // Pre-resolve the anchor as stock's getExtensionPrompt(position).trim() (script.js:4671-4687), so a
    // {{pick}} in the note seeds off THIS wrapped block and its offset, not off the whole story string.
    var anchor_owned: ?[]u8 = null;
    defer if (anchor_owned) |s| alloc.free(s);
    switch (shape.note.position) {
        .before_prompt => {
            const block = try buildNoteBlock(alloc, wi_act.an_top, wctx.anchor_before, wi_act.an_bottom, persona_an_txt, persona_an_top);
            defer alloc.free(block);
            anchor_owned = try resolveAnchorBlock(alloc, &.{block}, wctx);
            if (anchor_owned) |s| wctx.anchor_before = s;
        },
        .in_prompt => {
            const block = try buildNoteBlock(alloc, wi_act.an_top, wctx.anchor_after, wi_act.an_bottom, persona_an_txt, persona_an_top);
            defer alloc.free(block);
            anchor_owned = try resolveAnchorBlock(alloc, &.{block}, wctx);
            if (anchor_owned) |s| wctx.anchor_after = s;
        },
        .in_chat => {},
    }

    var overhead: std.ArrayList(u8) = .empty;
    errdefer overhead.deinit(alloc);

    // Persona story slot: only IN_PROMPT / AFTER_CHAR fill {{persona}} (stock gates the kv on
    // == IN_PROMPT, script.js:4677); other positions empty the slot but keep the persona macro elsewhere.
    var story_ctx = wctx;
    if (!shape.persona_position.fillsStory()) story_ctx.persona = "";
    const story = try templates.renderStoryString(alloc, shape.tpl.context.story_string, story_ctx, instruct);
    defer alloc.free(story);
    const wrapped_story = try templates.wrapStoryString(alloc, instruct, story);
    defer alloc.free(wrapped_story);
    try overhead.appendSlice(alloc, wrapped_story);

    try appendExamples(alloc, &overhead, wctx, shape.tpl.instruct, shape.tpl.context.example_separator, wi_act.em_top, wi_act.em_bottom);
    if (shape.tpl.context.chat_start.len > 0) {
        const start = try substituteMacros(alloc, shape.tpl.context.chat_start, wctx);
        defer alloc.free(start);
        try overhead.appendSlice(alloc, start);
        try overhead.append(alloc, '\n');
    }

    // Depth injections match stock doChatInject: contributions grouped by depth+role into one wrapped turn
    // each, jailbreak trailing. Ownership moves to the returned Pieces on success (free wrapped on error).
    var injections: std.ArrayList(AssembledInjection) = .empty;
    errdefer {
        for (injections.items) |inj| alloc.free(inj.wrapped);
        injections.deinit(alloc);
    }

    // Appended in stock extension_prompts key order (2_floating_prompt < DEPTH_PROMPT < PERSONA_DESCRIPTION
    // < customDepthWI) so groupInjections joins a shared depth+role the way getExtensionPrompt's .sort() does.
    var contribs: std.ArrayList(Contribution) = .empty;
    defer {
        for (contribs.items) |c| alloc.free(c.text);
        contribs.deinit(alloc);
    }
    // WI an entries force the note slot to fire even when the note itself is silent this turn
    // (stock shouldWIAddPrompt).
    // Contributions carry RAW text; groupInjections trims, joins, and substitutes the block once, so a
    // {{pick}} seeds off the joined block the way stock getExtensionPrompt does, not off one value alone.
    const an_wrap = shape.note.position == .in_chat and (wi_act.an_top.len > 0 or wi_act.an_bottom.len > 0);
    const persona_an_in_chat = persona_an and shape.note.position == .in_chat;
    if (an_wrap or persona_an_in_chat or authors_note.injectionIndex(shape.note, history.len) != null) {
        const note_text = if (authors_note.injectionIndex(shape.note, history.len) != null) shape.note.prompt else "";
        const inchat_persona: []const u8 = if (persona_an_in_chat) persona_an_txt else "";
        const joined = try buildNoteBlock(alloc, wi_act.an_top, note_text, wi_act.an_bottom, inchat_persona, persona_an_top);
        errdefer alloc.free(joined);
        try contribs.append(alloc, .{ .depth = @intCast(@max(0, shape.note.depth)), .role = shape.note.role.toTemplateRole(), .text = joined });
    }
    // The character's own depth note (stock "character-specific A/N"): always at its own depth+role.
    if (shape.char_note.prompt.len > 0) {
        const t = try alloc.dupe(u8, shape.char_note.prompt);
        errdefer alloc.free(t);
        try contribs.append(alloc, .{ .depth = @intCast(@max(0, shape.char_note.depth)), .role = shape.char_note.role.toTemplateRole(), .text = t });
    }
    // Persona AT_DEPTH (stock addPersonaDescriptionExtensionPrompt IN_CHAT branch, script.js:3190).
    if (shape.persona_position == .at_depth and wctx.persona.len > 0) {
        const t = try alloc.dupe(u8, wctx.persona);
        errdefer alloc.free(t);
        try contribs.append(alloc, .{ .depth = @intCast(@max(0, shape.persona_depth)), .role = roleFromInt(shape.persona_role), .text = t });
    }
    for (wi_act.at_depth) |g| {
        const t = try alloc.dupe(u8, g.content);
        errdefer alloc.free(t);
        try contribs.append(alloc, .{ .depth = @intCast(@max(0, g.depth)), .role = roleFromInt(g.role), .text = t });
    }

    try groupInjections(alloc, &injections, instruct, contribs.items, wctx);

    // The jailbreak / post-history instruction: stock's separate last user turn at depth 0, after the
    // depth-0 role groups (rank 3). Its {{original}} was resolved at composition.
    if (shape.jailbreak.len > 0) {
        const subbed = try substituteMacros(alloc, shape.jailbreak, wctx);
        defer alloc.free(subbed);
        const wrapped = try templates.wrapMessage(alloc, instruct, .user, "", subbed);
        errdefer alloc.free(wrapped);
        try injections.append(alloc, .{ .depth = 0, .rank = jailbreak_rank, .wrapped = wrapped });
    }

    // Each history turn pre-wrapped in its role's sequence, the string the caller tokenizes.
    var wh: std.ArrayList([]u8) = .empty;
    errdefer {
        for (wh.items) |x| alloc.free(x);
        wh.deinit(alloc);
    }
    for (history) |m| {
        const wrapped = try templates.wrapMessage(alloc, instruct, m.role, m.name, m.mes);
        errdefer alloc.free(wrapped);
        try wh.append(alloc, wrapped);
    }

    const prefix = try templates.continuationPrefix(alloc, instruct, ctx.char);
    errdefer alloc.free(prefix);

    // Stringify while wi_act's arena still backs the timed-effect keys (freed on scope exit).
    var timed_json: ?[]const u8 = null;
    errdefer if (timed_json) |j| alloc.free(j);
    if (want_timed) {
        var ja = std.heap.ArenaAllocator.init(alloc);
        defer ja.deinit();
        const v = try wi_engine.writeTimedState(ja.allocator(), wi_act.timed_out);
        timed_json = try std.json.Stringify.valueAlloc(alloc, v, .{});
    }

    const overhead_slice = try overhead.toOwnedSlice(alloc);
    errdefer alloc.free(overhead_slice);
    const inj_slice = try injections.toOwnedSlice(alloc);
    errdefer {
        for (inj_slice) |inj| alloc.free(inj.wrapped);
        alloc.free(inj_slice);
    }
    const wh_slice = try wh.toOwnedSlice(alloc);
    errdefer {
        for (wh_slice) |x| alloc.free(x);
        alloc.free(wh_slice);
    }
    return .{
        .overhead = overhead_slice,
        .injections = inj_slice,
        .wrapped_history = wh_slice,
        .prefix = prefix,
        .history_len = history.len,
        .collapse_newlines = shape.tpl.collapse_newlines,
        .timed_json = timed_json,
    };
}

/// An owned macro-resolved copy of the value, or the value itself when empty (no macro possible, no
/// allocation). Pairs with freeSeq, which frees iff the original was non-empty.
fn subSeq(alloc: Allocator, s: []const u8, ctx: Ctx) Allocator.Error![]const u8 {
    if (s.len == 0) return s;
    return substituteMacros(alloc, s, ctx);
}

fn freeSeq(alloc: Allocator, orig: []const u8, resolved: []const u8) void {
    if (orig.len > 0) alloc.free(resolved);
}

/// Resolves macros in the instruct wrap sequences, honoring the template's own `macro` toggle. When
/// off, returns the template unchanged with nothing allocated; else every sequence field is an owned
/// copy (free with freeInstructMacros). See the call site in buildPromptBudgeted for the why.
fn resolveInstructMacros(alloc: Allocator, tpl: templates.Instruct, ctx: Ctx) Allocator.Error!templates.Instruct {
    if (!tpl.macro) return tpl;
    const in_seq = try subSeq(alloc, tpl.input_sequence, ctx);
    errdefer freeSeq(alloc, tpl.input_sequence, in_seq);
    const in_suf = try subSeq(alloc, tpl.input_suffix, ctx);
    errdefer freeSeq(alloc, tpl.input_suffix, in_suf);
    const out_seq = try subSeq(alloc, tpl.output_sequence, ctx);
    errdefer freeSeq(alloc, tpl.output_sequence, out_seq);
    const out_suf = try subSeq(alloc, tpl.output_suffix, ctx);
    errdefer freeSeq(alloc, tpl.output_suffix, out_suf);
    const sys_seq = try subSeq(alloc, tpl.system_sequence, ctx);
    errdefer freeSeq(alloc, tpl.system_sequence, sys_seq);
    const sys_suf = try subSeq(alloc, tpl.system_suffix, ctx);
    errdefer freeSeq(alloc, tpl.system_suffix, sys_suf);
    const first_out = try subSeq(alloc, tpl.first_output_sequence, ctx);
    errdefer freeSeq(alloc, tpl.first_output_sequence, first_out);
    const last_out = try subSeq(alloc, tpl.last_output_sequence, ctx);
    errdefer freeSeq(alloc, tpl.last_output_sequence, last_out);
    const stop = try subSeq(alloc, tpl.stop_sequence, ctx);
    errdefer freeSeq(alloc, tpl.stop_sequence, stop);
    const ss_pre = try subSeq(alloc, tpl.story_string_prefix, ctx);
    errdefer freeSeq(alloc, tpl.story_string_prefix, ss_pre);
    const ss_suf = try subSeq(alloc, tpl.story_string_suffix, ctx);
    errdefer freeSeq(alloc, tpl.story_string_suffix, ss_suf);

    var r = tpl;
    r.input_sequence = in_seq;
    r.input_suffix = in_suf;
    r.output_sequence = out_seq;
    r.output_suffix = out_suf;
    r.system_sequence = sys_seq;
    r.system_suffix = sys_suf;
    r.first_output_sequence = first_out;
    r.last_output_sequence = last_out;
    r.stop_sequence = stop;
    r.story_string_prefix = ss_pre;
    r.story_string_suffix = ss_suf;
    return r;
}

fn freeInstructMacros(alloc: Allocator, orig: templates.Instruct, r: templates.Instruct) void {
    if (!orig.macro) return;
    freeSeq(alloc, orig.input_sequence, r.input_sequence);
    freeSeq(alloc, orig.input_suffix, r.input_suffix);
    freeSeq(alloc, orig.output_sequence, r.output_sequence);
    freeSeq(alloc, orig.output_suffix, r.output_suffix);
    freeSeq(alloc, orig.system_sequence, r.system_sequence);
    freeSeq(alloc, orig.system_suffix, r.system_suffix);
    freeSeq(alloc, orig.first_output_sequence, r.first_output_sequence);
    freeSeq(alloc, orig.last_output_sequence, r.last_output_sequence);
    freeSeq(alloc, orig.stop_sequence, r.stop_sequence);
    freeSeq(alloc, orig.story_string_prefix, r.story_string_prefix);
    freeSeq(alloc, orig.story_string_suffix, r.story_string_suffix);
}

fn storyHasSlot(story: []const u8, slot: []const u8, legacy: []const u8) bool {
    return std.mem.indexOf(u8, story, slot) != null or std.mem.indexOf(u8, story, legacy) != null;
}

/// The non-empty parts joined with newlines. Owned result, possibly empty.
/// Resolves an author's-note anchor the way stock getExtensionPrompt(position).trim() does: trim each
/// value, drop the empties, join with '\n', wrap with a leading and trailing '\n', run one macro pass
/// over the wrapped block, then trim. Wrapping first gives a {{pick}} the block-relative offset stock
/// seeds it on (script.js:3286-3298 + 4687). Null when every value is empty, so the caller leaves the
/// slot untouched and its `{{#if}}` drops. Owned result.
fn resolveAnchorBlock(alloc: Allocator, values: []const []const u8, ctx: Ctx) Allocator.Error!?[]u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (values) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len == 0) continue;
        if (joined.items.len > 0) try joined.append(alloc, '\n');
        try joined.appendSlice(alloc, t);
    }
    if (joined.items.len == 0) return null;

    const wrapped = try std.fmt.allocPrint(alloc, "\n{s}\n", .{joined.items});
    defer alloc.free(wrapped);
    const resolved = try macros.substituteMacros(alloc, wrapped, ctx);
    defer alloc.free(resolved);
    return try alloc.dupe(u8, std.mem.trim(u8, resolved, " \t\r\n"));
}

/// Builds the author's-note block in stock's two stages. World-info.js:5149 wraps the WI an_top/an_bottom
/// around the note as `${top}\n${note}\n${bottom}` with exactly one leading and one trailing '\n' stripped,
/// so an empty note between two anchors leaves a blank line (the double '\n'). Script.js:3184 then wraps the
/// TOP_AN / BOTTOM_AN persona OUTSIDE that; an empty `persona` skips the persona stage. Owned result.
fn buildNoteBlock(alloc: Allocator, an_top: []const u8, note: []const u8, an_bottom: []const u8, persona: []const u8, persona_top: bool) Allocator.Error![]u8 {
    const s1 = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ an_top, note, an_bottom });
    defer alloc.free(s1);
    var wi = s1;
    if (wi.len > 0 and wi[0] == '\n') wi = wi[1..];
    if (wi.len > 0 and wi[wi.len - 1] == '\n') wi = wi[0 .. wi.len - 1];
    if (persona.len == 0) return alloc.dupe(u8, wi);
    return if (persona_top)
        std.fmt.allocPrint(alloc, "{s}\n{s}", .{ persona, wi })
    else
        std.fmt.allocPrint(alloc, "{s}\n{s}", .{ wi, persona });
}

/// The example section, ported from the classic two-stage pipeline: parseMesExamples (script.js:3469)
/// normalizes the card + WI example entries into `<START>`-delimited blocks, then
/// formatInstructModeExamples (instruct-mode.js:512) wraps each example turn in the instruct
/// input/output sequences the same way a real chat turn is wrapped. WI em_top entries come first, then
/// the card's example dialogue, then em_bottom, matching the classic unshift/push order into
/// mesExamplesArray (script.js:4619-4624). All intermediate allocation lives in a scratch arena; only
/// the final joined section is copied into `out`. Solo path only: group names are never appended.
fn appendExamples(alloc: Allocator, out: *std.ArrayList(u8), ctx: Ctx, tpl: templates.Instruct, example_separator: []const u8, em_top: []const []const u8, em_bottom: []const []const u8) Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // blockHeading in both stages keys on the RAW separator being non-empty, then uses its resolved
    // value plus '\n' (instruct-mode.js:513 + script.js:3478). parseMesExamples uses '<START>\n' in
    // instruct mode instead, so the tag survives into formatInstructModeExamples' cleanedItem step.
    const sep_resolved = try substituteMacros(a, example_separator, ctx);
    const sep_heading: []const u8 = if (example_separator.len > 0)
        try std.fmt.allocPrint(a, "{s}\n", .{sep_resolved})
    else
        "";
    const pme_heading: []const u8 = if (tpl.enabled) "<START>\n" else sep_heading;

    var blocks: std.ArrayList([]const u8) = .empty;
    for (em_top) |e| {
        const subbed = try subAndStripCR(a, e, ctx);
        for (try parseMesExamples(a, subbed, pme_heading)) |p| try blocks.append(a, p);
    }
    if (ctx.mes_example.len > 0) {
        const trimmed = std.mem.trim(u8, ctx.mes_example, &std.ascii.whitespace);
        const subbed = try subAndStripCR(a, trimmed, ctx);
        for (try parseMesExamples(a, subbed, pme_heading)) |p| try blocks.append(a, p);
    }
    for (em_bottom) |e| {
        const subbed = try subAndStripCR(a, e, ctx);
        for (try parseMesExamples(a, subbed, pme_heading)) |p| try blocks.append(a, p);
    }
    if (blocks.items.len == 0) return;

    const section: []const u8 = if (tpl.enabled)
        try formatInstructModeExamples(a, blocks.items, ctx.user, ctx.char, tpl, sep_heading, ctx, false)
    else blk: {
        var o: std.ArrayList(u8) = .empty;
        for (blocks.items) |b| try o.appendSlice(a, b);
        break :blk try o.toOwnedSlice(a);
    };
    try out.appendSlice(alloc, section);
}

/// The {{mesExamples}} macro value (env-macros.js:105): parse the raw card examples, then join them -
/// instruct-wrapped via formatInstructModeExamples when instruct is enabled, else the parsed blocks
/// verbatim. Empty when the raw yields no block. Owned. Mirrors the story-string example pipeline
/// (appendExamples) minus the WI em_top/em_bottom entries; the macro always joins on ''.
pub fn renderMesExamplesMacro(alloc: Allocator, raw: []const u8, name1: []const u8, name2: []const u8, tpl: templates.Instruct, example_separator: []const u8, ctx: Ctx) Allocator.Error![]u8 {
    if (raw.len == 0) return alloc.dupe(u8, "");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sep_resolved = try substituteMacros(a, example_separator, ctx);
    const sep_heading: []const u8 = if (example_separator.len > 0)
        try std.fmt.allocPrint(a, "{s}\n", .{sep_resolved})
    else
        "";
    const pme_heading: []const u8 = if (tpl.enabled) "<START>\n" else sep_heading;

    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    const blocks = try parseMesExamples(a, trimmed, pme_heading);
    if (blocks.len == 0) return alloc.dupe(u8, "");

    if (!tpl.enabled) {
        var o: std.ArrayList(u8) = .empty;
        for (blocks) |b| try o.appendSlice(a, b);
        return alloc.dupe(u8, o.items);
    }
    const formatted = try formatInstructModeExamples(a, blocks, name1, name2, tpl, sep_heading, ctx, false);
    return alloc.dupe(u8, formatted);
}

/// baseChatReplace (script.js:3309) for an example field: resolve macros, then strip every CR. The
/// caller trims the card field first; WI entries pass through untrimmed, matching the reference.
fn subAndStripCR(a: Allocator, s: []const u8, ctx: Ctx) Allocator.Error![]u8 {
    const subbed = try substituteMacros(a, s, ctx);
    return stripCR(a, subbed);
}

/// A copy of `s` with every CR removed (JS `.replace(/\r/gm, '')`). Owned.
fn stripCR(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c != '\r') try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

/// The index of the first case-insensitive `needle` in `s` at or after `start`, or null.
fn indexOfCI(s: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (needle.len > s.len) return null;
    var i = start;
    while (i + needle.len <= s.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(s[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// A copy of `s` with the first case-insensitive `needle` replaced by `repl` (JS `.replace(/needle/i,
/// repl)`). Unmatched returns a plain copy. Owned.
fn replaceFirstCI(a: Allocator, s: []const u8, needle: []const u8, repl: []const u8) Allocator.Error![]u8 {
    if (indexOfCI(s, needle, 0)) |idx| {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, s[0..idx]);
        try out.appendSlice(a, repl);
        try out.appendSlice(a, s[idx + needle.len ..]);
        return out.toOwnedSlice(a);
    }
    return a.dupe(u8, s);
}

/// A copy of `s` with the first exact `needle` removed (JS `.replace(needle, '')`). Owned.
fn removeFirstLiteral(a: Allocator, s: []const u8, needle: []const u8) Allocator.Error![]u8 {
    if (std.mem.indexOf(u8, s, needle)) |idx| {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, s[0..idx]);
        try out.appendSlice(a, s[idx + needle.len ..]);
        return out.toOwnedSlice(a);
    }
    return a.dupe(u8, s);
}

/// parseMesExamples (script.js:3469): normalize `examplesStr` to a `<START>`-prefixed string, split on
/// every case-insensitive `<START>`, drop the leading segment, and re-tag each block with `heading`
/// (`<START>\n` in instruct mode, else the resolved example separator). Owned array of owned blocks.
fn parseMesExamples(a: Allocator, examples_str: []const u8, heading: []const u8) Allocator.Error![]const []const u8 {
    if (examples_str.len == 0 or std.mem.eql(u8, examples_str, "<START>")) return &.{};

    var s = examples_str;
    if (!std.mem.startsWith(u8, s, "<START>")) {
        const t = std.mem.trim(u8, s, &std.ascii.whitespace);
        s = try std.fmt.allocPrint(a, "<START>\n{s}", .{t});
    }

    var result: std.ArrayList([]const u8) = .empty;
    var seg_start: usize = 0;
    var first = true;
    var i: usize = 0;
    while (true) {
        const found = indexOfCI(s, "<START>", i);
        const cut = found orelse s.len;
        if (first) {
            first = false;
        } else {
            const bt = std.mem.trim(u8, s[seg_start..cut], &std.ascii.whitespace);
            try result.append(a, try std.fmt.allocPrint(a, "{s}{s}\n", .{ heading, bt }));
        }
        if (found == null) break;
        seg_start = cut + "<START>".len;
        i = seg_start;
    }
    return result.toOwnedSlice(a);
}

const ExampleTurn = struct { is_user: bool, content: []const u8 };

/// parseExampleIntoIndividual (openai.js:724) for the solo case: split a cleaned block into user/char
/// turns on the `name1:` / `name2:` line prefixes, strip the name prefix from each turn's content, and
/// trim. The first line is always the "This is how X should talk" heading and is skipped. Owned.
fn parseExampleIntoIndividual(a: Allocator, s: []const u8, name1: []const u8, name2: []const u8) Allocator.Error![]const ExampleTurn {
    const user_prefix = try std.fmt.allocPrint(a, "{s}:", .{name1});
    const bot_prefix = try std.fmt.allocPrint(a, "{s}:", .{name2});

    var result: std.ArrayList(ExampleTurn) = .empty;
    var cur: std.ArrayList([]const u8) = .empty;
    var in_user = false;
    var in_bot = false;

    var it = std.mem.splitScalar(u8, s, '\n');
    _ = it.next();
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, user_prefix)) {
            in_user = true;
            if (in_bot) try addExampleTurn(a, &result, &cur, name2, false);
            in_bot = false;
        } else if (std.mem.startsWith(u8, line, bot_prefix)) {
            in_bot = true;
            if (in_user) try addExampleTurn(a, &result, &cur, name1, true);
            in_user = false;
        }
        try cur.append(a, line);
    }
    if (in_user) {
        try addExampleTurn(a, &result, &cur, name1, true);
    } else if (in_bot) {
        try addExampleTurn(a, &result, &cur, name2, false);
    }
    return result.toOwnedSlice(a);
}

fn addExampleTurn(a: Allocator, result: *std.ArrayList(ExampleTurn), cur: *std.ArrayList([]const u8), name: []const u8, is_user: bool) Allocator.Error!void {
    const joined = try std.mem.join(a, "\n", cur.items);
    const name_colon = try std.fmt.allocPrint(a, "{s}:", .{name});
    const removed = try removeFirstLiteral(a, joined, name_colon);
    const content = std.mem.trim(u8, removed, &std.ascii.whitespace);
    try result.append(a, .{ .is_user = is_user, .content = content });
    cur.clearRetainingCapacity();
}

/// formatInstructModeExamples (instruct-mode.js:512) for the solo path. Each block's turns are wrapped
/// in the instruct input/output sequences; the block heading precedes every non-empty block. When
/// `skip_examples` is set the reference does no wrapping, only swapping `<START>\n` for the heading.
/// `skip_examples` is threaded as an argument rather than a template field because this client leaves
/// power_user.instruct.skip_examples unmodelled (preset_lib.zig: at type default in every shipped
/// preset bar one); production always passes false. Owned joined section.
fn formatInstructModeExamples(a: Allocator, blocks: []const []const u8, name1: []const u8, name2: []const u8, tpl: templates.Instruct, block_heading: []const u8, ctx: Ctx, skip_examples: bool) Allocator.Error![]u8 {
    if (skip_examples) return replaceStartHeadings(a, blocks, block_heading);

    const include_names = tpl.names_behavior == .always;
    var input_prefix: []const u8 = tpl.input_sequence;
    var output_prefix: []const u8 = tpl.output_sequence;
    var input_suffix: []const u8 = tpl.input_suffix;
    var output_suffix: []const u8 = tpl.output_suffix;
    if (tpl.macro) {
        input_prefix = try replaceNameToken(a, try substituteMacros(a, input_prefix, ctx), name1);
        output_prefix = try replaceNameToken(a, try substituteMacros(a, output_prefix, ctx), name2);
        input_suffix = try replaceNameToken(a, try substituteMacros(a, input_suffix, ctx), name1);
        output_suffix = try replaceNameToken(a, try substituteMacros(a, output_suffix, ctx), name2);
        if (input_suffix.len == 0 and tpl.wrap) input_suffix = "\n";
        if (output_suffix.len == 0 and tpl.wrap) output_suffix = "\n";
    }
    const separator: []const u8 = if (tpl.wrap) "\n" else "";

    var formatted: std.ArrayList([]const u8) = .empty;
    for (blocks) |item| {
        const swapped = try replaceFirstCI(a, item, "<START>", "{Example Dialogue:}");
        const cleaned = try stripCR(a, swapped);
        const turns = try parseExampleIntoIndividual(a, cleaned, name1, name2);
        if (turns.len == 0) continue;
        if (block_heading.len > 0) try formatted.append(a, block_heading);
        for (turns) |t| {
            const include_this = include_names or (tpl.names_behavior == .force and t.is_user);
            const prefix = if (t.is_user) input_prefix else output_prefix;
            const suffix = if (t.is_user) input_suffix else output_suffix;
            const nm = if (t.is_user) name1 else name2;
            const msg_content: []const u8 = if (include_this)
                try std.fmt.allocPrint(a, "{s}: {s}", .{ nm, t.content })
            else
                t.content;
            const content_plus = try std.fmt.allocPrint(a, "{s}{s}", .{ msg_content, suffix });
            try formatted.append(a, try filterJoin(a, prefix, content_plus, separator));
        }
    }

    if (formatted.items.len == 0) return replaceStartHeadings(a, blocks, block_heading);

    var out: std.ArrayList(u8) = .empty;
    for (formatted.items) |f| try out.appendSlice(a, f);
    return out.toOwnedSlice(a);
}

/// The reference's fallback join: `blocks.map(x => x.replace(/<START>\n/i, blockHeading)).join('')`.
fn replaceStartHeadings(a: Allocator, blocks: []const []const u8, block_heading: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (blocks) |item| {
        const r = try replaceFirstCI(a, item, "<START>\n", block_heading);
        try out.appendSlice(a, r);
    }
    return out.toOwnedSlice(a);
}

/// JS `[p1, p2].filter(x => x).join(sep)`: empty strings are dropped before the join. Owned.
fn filterJoin(a: Allocator, p1: []const u8, p2: []const u8, sep: []const u8) Allocator.Error![]u8 {
    if (p1.len > 0 and p2.len > 0) return std.fmt.allocPrint(a, "{s}{s}{s}", .{ p1, sep, p2 });
    if (p1.len > 0) return a.dupe(u8, p1);
    return a.dupe(u8, p2);
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

/// The full stopping-string set the classic client sends for a SOLO text-completion send, replicating
/// getStoppingStrings (script.js:2993) for the non-openai, non-impersonate, non-continue, non-group
/// path. Order and dedup match the reference so the emitted array is byte-identical to the old
/// frontend's: names (script.js:3001) -> instruct sequences + chat_start/example_separator
/// (instruct-mode.js:302) -> custom stopping strings (power-user.js:3058), single_line prepends '\n',
/// then falsy-drop + onlyUnique over the whole list. Impersonate/continue/group are out of scope.
///
/// `name1` is the user/persona name, `name2` the character name. Returns an owned array of owned
/// strings (each independent of `tpl` and `ctx`); the caller frees each element then the array.
pub fn buildStoppingStrings(alloc: Allocator, tpl: templates.Templates, ctx: Ctx, name1: []const u8, name2: []const u8) Allocator.Error![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| alloc.free(s);
        list.deinit(alloc);
    }

    if (tpl.context.names_as_stop_strings) {
        // The reference pushes the user string twice (isImpersonate false -> userString, then userString
        // again); the trailing onlyUnique collapses them. Two owned copies keep the pre-dedup shape.
        try pushOwned(alloc, &list, try std.fmt.allocPrint(alloc, "\n{s}:", .{name1}));
        try pushOwned(alloc, &list, try std.fmt.allocPrint(alloc, "\n{s}:", .{name1}));
    }

    try appendInstructStops(alloc, &list, tpl.instruct, ctx, name1, name2);

    if (tpl.context.use_stop_strings) {
        if (tpl.context.chat_start.len > 0) try appendPrefixedMacro(alloc, &list, tpl.context.chat_start, ctx);
        if (tpl.context.example_separator.len > 0) try appendPrefixedMacro(alloc, &list, tpl.context.example_separator, ctx);
    }

    try appendCustomStops(alloc, &list, tpl, ctx);

    if (tpl.single_line) {
        const nl = try alloc.dupe(u8, "\n");
        list.insert(alloc, 0, nl) catch |e| {
            alloc.free(nl);
            return e;
        };
    }

    // filter(x => x).filter(onlyUnique): drop empties, keep the first of each duplicate, in place.
    var w: usize = 0;
    outer: for (list.items) |s| {
        if (s.len == 0) {
            alloc.free(s);
            continue;
        }
        for (list.items[0..w]) |kept| {
            if (std.mem.eql(u8, kept, s)) {
                alloc.free(s);
                continue :outer;
            }
        }
        list.items[w] = s;
        w += 1;
    }
    list.shrinkRetainingCapacity(w);
    return list.toOwnedSlice(alloc);
}

/// Appends an already-owned string to `list`, freeing it if the append itself fails so a mid-build
/// OOM leaks nothing. On success `list` owns the string and the caller's outer errdefer covers it.
fn pushOwned(alloc: Allocator, list: *std.ArrayList([]u8), s: []u8) Allocator.Error!void {
    errdefer alloc.free(s);
    try list.append(alloc, s);
}

/// One stopping string prefixed with '\n' and macro-substituted, pushed to `list`. Matches the
/// `\n${substituteParams(x)}` the reference uses for chat_start and example_separator.
fn appendPrefixedMacro(alloc: Allocator, list: *std.ArrayList([]u8), raw: []const u8, ctx: Ctx) Allocator.Error!void {
    const subbed = try substituteMacros(alloc, raw, ctx);
    defer alloc.free(subbed);
    try pushOwned(alloc, list, try std.fmt.allocPrint(alloc, "\n{s}", .{subbed}));
}

/// The instruct-mode stopping sequences (getInstructStoppingSequences, instruct-mode.js:302): the
/// stop_sequence plus, when sequences_as_stop_strings is set, every wrap sequence with its {{name}}
/// token resolved per family (input -> user, output -> char, system -> "System"). The combined set is
/// joined on '\n', re-split, deduped, and each non-blank line is wrapped ('\n' prefix when wrap) and
/// macro-substituted, exactly as addInstructSequence does.
fn appendInstructStops(alloc: Allocator, list: *std.ArrayList([]u8), ins: templates.Instruct, ctx: Ctx, name1: []const u8, name2: []const u8) Allocator.Error!void {
    if (!ins.enabled) return;

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    // The reference does not resolve {{name}} in stop_sequence, only in the wrap sequences.
    try joined.appendSlice(alloc, ins.stop_sequence);
    if (ins.sequences_as_stop_strings) {
        const mapped = [_]struct { seq: []const u8, name: []const u8 }{
            .{ .seq = ins.input_sequence, .name = name1 },
            .{ .seq = ins.output_sequence, .name = name2 },
            .{ .seq = ins.first_output_sequence, .name = name2 },
            .{ .seq = ins.last_output_sequence, .name = name2 },
            .{ .seq = ins.system_sequence, .name = "System" },
            .{ .seq = ins.last_system_sequence, .name = "System" },
        };
        for (mapped) |m| {
            const resolved = try replaceNameToken(alloc, m.seq, m.name);
            defer alloc.free(resolved);
            try joined.append(alloc, '\n');
            try joined.appendSlice(alloc, resolved);
        }
    }

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(alloc);
    var it = std.mem.splitScalar(u8, joined.items, '\n');
    while (it.next()) |line| {
        var dup = false;
        for (seen.items) |prev| {
            if (std.mem.eql(u8, prev, line)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        try seen.append(alloc, line);
        if (isBlank(line)) continue;
        const wrapped = if (ins.wrap)
            try std.fmt.allocPrint(alloc, "\n{s}", .{line})
        else
            try alloc.dupe(u8, line);
        if (ins.macro) {
            defer alloc.free(wrapped);
            try pushOwned(alloc, list, try substituteMacros(alloc, wrapped, ctx));
        } else {
            try pushOwned(alloc, list, wrapped);
        }
    }
}

/// The custom stopping strings (getCustomStoppingStrings, power-user.js:3058): the JSON-array string
/// parsed, non-string and empty entries dropped, each macro-substituted when the macro toggle is set.
/// A malformed JSON string yields no custom stops, as the reference's try/catch does.
fn appendCustomStops(alloc: Allocator, list: *std.ArrayList([]u8), tpl: templates.Templates, ctx: Ctx) Allocator.Error!void {
    if (tpl.custom_stopping_strings.len == 0) return;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, tpl.custom_stopping_strings, .{}) catch return;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return,
    };
    for (arr.items) |item| {
        const s = switch (item) {
            .string => |str| str,
            else => continue,
        };
        if (s.len == 0) continue;
        if (tpl.custom_stopping_strings_macro) {
            try pushOwned(alloc, list, try substituteMacros(alloc, s, ctx));
        } else {
            try pushOwned(alloc, list, try alloc.dupe(u8, s));
        }
    }
}

/// A copy of `input` with every case-insensitive `{{name}}` token replaced by `name`. Matches the
/// reference's `.replace(/{{name}}/gi, name)`. Owned.
fn replaceNameToken(alloc: Allocator, input: []const u8, name: []const u8) Allocator.Error![]u8 {
    const token = "{{name}}";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        if (i + token.len <= input.len and std.ascii.eqlIgnoreCase(input[i .. i + token.len], token)) {
            try out.appendSlice(alloc, name);
            i += token.len;
        } else {
            try out.append(alloc, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// True when every byte is ASCII whitespace, so the reference's `sequence.trim().length > 0` guard
/// would drop it. A blank line contributes no stopping string.
fn isBlank(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

/// The effective main/system prompt, composed as stock does (script.js:4656-4663): a disabled global
/// drops it entirely; else a card/chat override wins over the global when prefer_character_prompt is on
/// and the override is non-empty; else the global. Borrowed from the inputs.
pub fn effectiveSystem(sysprompt_enabled: bool, prefer_character_prompt: bool, override: []const u8, global: []const u8) []const u8 {
    if (!sysprompt_enabled) return "";
    if (prefer_character_prompt and override.len > 0) return override;
    return global;
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
    try testing.expectEqualStrings("", conn.model);
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

test "extractConnection mines the per-type model field like getTextGenModel" {
    const cases = .{
        .{ "{\"main_api\":\"textgenerationwebui\",\"textgenerationwebui_settings\":{\"type\":\"llamacpp\",\"llamacpp_model\":\"Llama-3.1-8B.gguf\",\"server_urls\":{}}}", "Llama-3.1-8B.gguf" },
        .{ "{\"main_api\":\"textgenerationwebui\",\"textgenerationwebui_settings\":{\"type\":\"ooba\",\"custom_model\":\"mistral-nemo\",\"server_urls\":{}}}", "mistral-nemo" },
        .{ "{\"main_api\":\"textgenerationwebui\",\"textgenerationwebui_settings\":{\"type\":\"vllm\",\"vllm_model\":\"Qwen2-7B\",\"server_urls\":{}}}", "Qwen2-7B" },
        .{ "{\"main_api\":\"textgenerationwebui\",\"textgenerationwebui_settings\":{\"type\":\"huggingface\",\"server_urls\":{}}}", "tgi" },
        .{ "{\"main_api\":\"textgenerationwebui\",\"textgenerationwebui_settings\":{\"type\":\"koboldcpp\",\"server_urls\":{}}}", "" },
        .{ "{\"main_api\":\"textgenerationwebui\",\"textgenerationwebui_settings\":{\"type\":\"llamacpp\",\"server_urls\":{}}}", "" },
    };
    inline for (cases) |c| {
        const conn = try extractConnection(testing.allocator, c[0]);
        defer freeConnection(testing.allocator, conn);
        try testing.expectEqualStrings(c[1], conn.model);
    }
}

test "extractConnection mines power_user.token_padding, defaulting to 64" {
    const with = "{\"main_api\":\"textgenerationwebui\",\"power_user\":{\"token_padding\":128},\"textgenerationwebui_settings\":{\"type\":\"llamacpp\",\"server_urls\":{}}}";
    const c1 = try extractConnection(testing.allocator, with);
    defer freeConnection(testing.allocator, c1);
    try testing.expectEqual(@as(i64, 128), c1.token_padding);

    const without = "{\"main_api\":\"textgenerationwebui\",\"textgenerationwebui_settings\":{\"type\":\"llamacpp\",\"server_urls\":{}}}";
    const c2 = try extractConnection(testing.allocator, without);
    defer freeConnection(testing.allocator, c2);
    try testing.expectEqual(@as(i64, 64), c2.token_padding);
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

const example_ctx = Ctx{ .user = "User", .char = "Char" };
const one_block = "<START>\nUser: hi\nChar: hello there\n";

test "formatInstructModeExamples wraps force-mode turns, user name only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tpl = chatml;
    tpl.names_behavior = .force;
    const out = try formatInstructModeExamples(a, &.{one_block}, "User", "Char", tpl, "***\n", example_ctx, false);
    try testing.expectEqualStrings(
        "***\n" ++
            "<|im_start|>user\nUser: hi<|im_end|>\n" ++
            "<|im_start|>assistant\nhello there<|im_end|>\n",
        out,
    );
}

test "formatInstructModeExamples always-mode names both speakers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tpl = chatml;
    tpl.names_behavior = .always;
    const out = try formatInstructModeExamples(a, &.{one_block}, "User", "Char", tpl, "***\n", example_ctx, false);
    try testing.expectEqualStrings(
        "***\n" ++
            "<|im_start|>user\nUser: hi<|im_end|>\n" ++
            "<|im_start|>assistant\nChar: hello there<|im_end|>\n",
        out,
    );
}

test "formatInstructModeExamples none-mode names neither speaker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tpl = chatml;
    tpl.names_behavior = .none;
    const out = try formatInstructModeExamples(a, &.{one_block}, "User", "Char", tpl, "***\n", example_ctx, false);
    try testing.expectEqualStrings(
        "***\n" ++
            "<|im_start|>user\nhi<|im_end|>\n" ++
            "<|im_start|>assistant\nhello there<|im_end|>\n",
        out,
    );
}

test "formatInstructModeExamples drops the wrap separator when wrap is off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tpl = chatml;
    tpl.names_behavior = .force;
    tpl.wrap = false;
    const out = try formatInstructModeExamples(a, &.{one_block}, "User", "Char", tpl, "***\n", example_ctx, false);
    try testing.expectEqualStrings(
        "***\n" ++
            "<|im_start|>userUser: hi<|im_end|>\n" ++
            "<|im_start|>assistanthello there<|im_end|>\n",
        out,
    );
}

test "formatInstructModeExamples skip_examples only swaps the START heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tpl = chatml;
    tpl.names_behavior = .force;
    const out = try formatInstructModeExamples(a, &.{one_block}, "User", "Char", tpl, "***\n", example_ctx, true);
    try testing.expectEqualStrings("***\nUser: hi\nChar: hello there\n", out);
}

test "formatInstructModeExamples emits the block heading before every non-empty block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tpl = chatml;
    tpl.names_behavior = .force;
    const blocks = [_][]const u8{ "<START>\nUser: a\nChar: b\n", "<START>\nUser: c\nChar: d\n" };
    const out = try formatInstructModeExamples(a, &blocks, "User", "Char", tpl, "***\n", example_ctx, false);
    try testing.expectEqualStrings(
        "***\n<|im_start|>user\nUser: a<|im_end|>\n<|im_start|>assistant\nb<|im_end|>\n" ++
            "***\n<|im_start|>user\nUser: c<|im_end|>\n<|im_start|>assistant\nd<|im_end|>\n",
        out,
    );
}

test "formatInstructModeExamples omits headings when the separator is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tpl = chatml;
    tpl.names_behavior = .force;
    const out = try formatInstructModeExamples(a, &.{one_block}, "User", "Char", tpl, "", example_ctx, false);
    try testing.expectEqualStrings(
        "<|im_start|>user\nUser: hi<|im_end|>\n<|im_start|>assistant\nhello there<|im_end|>\n",
        out,
    );
}

test "parseMesExamples tags the block with the instruct heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = try parseMesExamples(a, "<START>\nUser: hi\nChar: hello there", "<START>\n");
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqualStrings("<START>\nUser: hi\nChar: hello there\n", blocks[0]);
}

test "parseMesExamples prepends START and splits multiple blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = try parseMesExamples(a, "User: a\nChar: b\n<START>\nUser: c\nChar: d", "<START>\n");
    try testing.expectEqual(@as(usize, 2), blocks.len);
    try testing.expectEqualStrings("<START>\nUser: a\nChar: b\n", blocks[0]);
    try testing.expectEqualStrings("<START>\nUser: c\nChar: d\n", blocks[1]);
}

test "renderMesExamplesMacro joins parsed blocks verbatim when instruct is off" {
    const ctx = Ctx{};
    const out = try renderMesExamplesMacro(testing.allocator, "<START>\nA: x\nB: y", "A", "B", .{ .enabled = false }, "", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("A: x\nB: y\n", out);
}

test "renderMesExamplesMacro instruct-wraps each example turn" {
    const ctx = Ctx{ .user = "User", .char = "Char" };
    const out = try renderMesExamplesMacro(testing.allocator, "<START>\nUser: hi\nChar: hello", "User", "Char", chatml, "", ctx);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<|im_start|>user\nhi<|im_end|>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<|im_start|>assistant\nhello<|im_end|>") != null);
}

test "renderMesExamplesMacro is empty for empty raw" {
    const ctx = Ctx{};
    const out = try renderMesExamplesMacro(testing.allocator, "", "A", "B", .{ .enabled = true }, "", ctx);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "parseExampleIntoIndividual splits turns and strips the name prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = try parseExampleIntoIndividual(a, "{Example Dialogue:}\nUser: hi\nChar: hello there", "User", "Char");
    try testing.expectEqual(@as(usize, 2), turns.len);
    try testing.expect(turns[0].is_user);
    try testing.expectEqualStrings("hi", turns[0].content);
    try testing.expect(!turns[1].is_user);
    try testing.expectEqualStrings("hello there", turns[1].content);
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
        // the story sits flush against its suffix; stock adds a trailing newline only when the
        // instruct has no story_string_suffix (power-user.js:2243), which ChatML does.
        "<|im_start|>system\nA diver.<|im_end|>\n" ++
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

test "buildPrompt resolves macros in the instruct wrap sequences" {
    // A template whose output_sequence carries {{char}} must reach the model resolved, not literal:
    // live prompts showed the char prefix as "<|im_start|>assistant {{char}}:".
    var tpl = chatml;
    tpl.output_sequence = "<|im_start|>assistant {{char}}:";
    const shape = Shape{ .tpl = .{ .instruct = tpl, .context = .{ .story_string = templates.default_story_string } } };
    const ctx = Ctx{ .char = "Lena", .description = "A diver." };
    const out = try buildPrompt(testing.allocator, ctx, &.{}, shape);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "{{char}}") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<|im_start|>assistant Lena:") != null);
}

test "effectiveSystem: card override wins, global falls back, disabled drops" {
    try testing.expectEqualStrings("", effectiveSystem(false, true, "CARD", "GLOBAL"));
    try testing.expectEqualStrings("CARD", effectiveSystem(true, true, "CARD", "GLOBAL"));
    try testing.expectEqualStrings("GLOBAL", effectiveSystem(true, true, "", "GLOBAL"));
    try testing.expectEqualStrings("GLOBAL", effectiveSystem(true, false, "CARD", "GLOBAL"));
}

test "buildPrompt appends the jailbreak as a user turn after the history" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie" };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "Hi.", .role = .user }};
    const shape = Shape{ .tpl = .{ .instruct = chatml, .context = .{ .story_string = "" } }, .jailbreak = "Reply as {{char}} only." };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    const hi = std.mem.indexOf(u8, out, "Hi.") orelse return error.NoHistory;
    const jb = std.mem.indexOf(u8, out, "Reply as Rita only.") orelse return error.NoJailbreak;
    try testing.expect(jb > hi); // JB lands after the history, before the assistant prefix
}

test "buildPrompt injects the character depth note at its depth and role" {
    const ctx = Ctx{ .char = "Rita" };
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "one", .role = .user },
        .{ .name = "Rita", .mes = "two", .role = .assistant },
        .{ .name = "Jamie", .mes = "three", .role = .user },
    };
    // depth 1 lands the note one turn from the end: after "two", before the last turn "three".
    const shape = Shape{ .tpl = .{ .instruct = chatml, .context = .{ .story_string = "" } }, .char_note = .{ .prompt = "CHARNOTE for {{char}}", .depth = 1, .role = .system } };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    const note = std.mem.indexOf(u8, out, "CHARNOTE for Rita") orelse return error.NoNote;
    const two = std.mem.indexOf(u8, out, "two").?;
    const three = std.mem.indexOf(u8, out, "three").?;
    try testing.expect(note > two and note < three);
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

test "fitWindow keeps the newest suffix strictly under the budget as a start index" {
    const costs = [_]usize{ 6, 6, 6, 6, 6 };
    try testing.expectEqual(@as(usize, 2), fitWindow(&costs, 19)); // 18 < 19 -> keeps 3
    // Strict: a cumulative that exactly equals the budget is excluded (classic tokenCount < ctx).
    try testing.expectEqual(@as(usize, 3), fitWindow(&costs, 18)); // 18 == 18 -> keeps 2
    try testing.expectEqual(@as(usize, 0), fitWindow(&costs, 1000)); // keeps all 5
}

test "fitWindow drops even the newest turn when it does not fit (no forced keep)" {
    const costs = [_]usize{ 5, 4 }; // index 1 is the newest (cost 4)
    try testing.expectEqual(@as(usize, 2), fitWindow(&costs, 0)); // budget 0 -> empty history
    try testing.expectEqual(@as(usize, 2), fitWindow(&costs, 4)); // newest 4 == 4 excluded -> empty
    try testing.expectEqual(@as(usize, 1), fitWindow(&costs, 5)); // newest 4 < 5 kept, older 9 dropped
    const empty = [_]usize{};
    try testing.expectEqual(@as(usize, 0), fitWindow(&empty, 100));
}

test "fitWindow charges each entry its own cost so a costlier wrap keeps fewer" {
    const cheap = [_]usize{ 6, 6, 6 };
    try testing.expectEqual(@as(usize, 0), fitWindow(&cheap, 31)); // 18 < 31 -> all three
    // Same budget, ChatML-sized turns (30 each) keep only the newest; wrapMessage length (== wrapCost)
    // is the byte-cost path's input, so the fallback trim stays template-aware.
    const heavy = [_]usize{ 30, 30, 30 };
    try testing.expectEqual(@as(usize, 2), fitWindow(&heavy, 31));
    try testing.expectEqual(@as(usize, 30), templates.wrapCost(chatml, .user, "A", "xx"));
}

test "fitAndAssemble trims history on a real per-turn token-cost table" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver." };
    const history = [_]PromptMsg{
        .{ .name = "R", .mes = "oldest" },
        .{ .name = "J", .mes = "middle" },
        .{ .name = "R", .mes = "newest" },
    };
    var pieces = try assemblePieces(testing.allocator, ctx, &history, .{}, false);
    defer freePieces(testing.allocator, &pieces);
    const hist_costs = [_]usize{ 10, 10, 10 };
    const costs = CostTable{ .overhead = 2, .injections = &.{}, .history = &hist_costs };

    const tight = try fitAndAssemble(testing.allocator, pieces, costs, 15);
    defer testing.allocator.free(tight);
    try testing.expect(std.mem.startsWith(u8, tight, "A diver.\n"));
    try testing.expect(std.mem.indexOf(u8, tight, "newest") != null);
    try testing.expect(std.mem.indexOf(u8, tight, "middle") == null);
    try testing.expect(std.mem.indexOf(u8, tight, "oldest") == null);

    const roomy = try fitAndAssemble(testing.allocator, pieces, costs, 25);
    defer testing.allocator.free(roomy);
    try testing.expect(std.mem.indexOf(u8, roomy, "middle") != null);
    try testing.expect(std.mem.indexOf(u8, roomy, "oldest") == null);
}

test "assemblePieces cleans up on every allocation failure" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .system = "You are {{char}}." };
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "Hi there.", .role = .user },
        .{ .name = "Rita", .mes = "Hello.", .role = .assistant },
    };
    const shape = Shape{
        .tpl = .{ .instruct = chatml, .context = .{ .story_string = templates.default_story_string } },
        .note = .{ .prompt = "Be terse.", .interval = 1, .position = .in_chat, .depth = 0, .role = .system },
        .char_note = .{ .prompt = "Depth note.", .depth = 1, .role = .system },
        .jailbreak = "Stay in character.",
    };
    const Runner = struct {
        fn run(alloc: Allocator, c: Ctx, h: []const PromptMsg, s: Shape) !void {
            var pieces = try assemblePieces(alloc, c, h, s, true);
            freePieces(alloc, &pieces);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Runner.run, .{ ctx, @as([]const PromptMsg, &history), shape });
}

test "fitAndAssemble cleans up on every allocation failure" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver." };
    const history = [_]PromptMsg{
        .{ .name = "R", .mes = "oldest" },
        .{ .name = "J", .mes = "middle" },
        .{ .name = "R", .mes = "newest" },
    };
    var pieces = try assemblePieces(testing.allocator, ctx, &history, .{}, false);
    defer freePieces(testing.allocator, &pieces);
    const hist_costs = [_]usize{ 10, 10, 10 };
    const costs = CostTable{ .overhead = 2, .injections = &.{}, .history = &hist_costs };
    const Runner = struct {
        fn run(alloc: Allocator, p: Pieces, c: CostTable) !void {
            const r = try fitAndAssemble(alloc, p, c, 25);
            alloc.free(r);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Runner.run, .{ pieces, costs });
}

test "buildPromptBudgeted trims history oldest-first but keeps the card block" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver." };
    const history = [_]PromptMsg{
        .{ .name = "Rita", .mes = "oldest line here" },
        .{ .name = "Jamie", .mes = "middle line here" },
        .{ .name = "Rita", .mes = "newest line here" },
    };
    const out = try buildPromptBudgeted(testing.allocator, ctx, &history, "A diver.\n".len + 24, .{}, null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "A diver.\n"));
    try testing.expect(std.mem.indexOf(u8, out, "newest line here") != null);
    try testing.expect(std.mem.indexOf(u8, out, "oldest line here") == null);
    try testing.expect(std.mem.endsWith(u8, out, "Rita:"));
}

test "promptCharBudget reserves the response and applies the char ratio" {
    const base = Connection{ .api_type = "", .api_server = "", .model = "", .token_padding = 0, .max_context = 8192, .max_tokens = 512, .temperature = 0, .top_p = 0, .top_k = 0, .min_p = 0, .rep_pen = 0 };
    try testing.expectEqual(@as(usize, (8192 - 512) * 7 / 2), promptCharBudget(base));
    const unset = Connection{ .api_type = "", .api_server = "", .model = "", .token_padding = 0, .max_context = 0, .max_tokens = 0, .temperature = 0, .top_p = 0, .top_k = 0, .min_p = 0, .rep_pen = 0 };
    try testing.expectEqual(@as(usize, 8192 * 7 / 2), promptCharBudget(unset));
}

test "both budgets reserve token_padding out of the history budget" {
    const conn = Connection{ .api_type = "", .api_server = "", .model = "", .token_padding = 64, .max_context = 8192, .max_tokens = 512, .temperature = 0, .top_p = 0, .top_k = 0, .min_p = 0, .rep_pen = 0 };
    try testing.expectEqual(@as(usize, 8192 - 512 - 64), promptTokenBudget(conn));
    try testing.expectEqual(@as(usize, (8192 - 512 - 64) * 7 / 2), promptCharBudget(conn));
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

test "a note survives even when a tight budget trims all history" {
    // Reserved note vs a budget too small even for the newest turn: the whole history drops (classic
    // script.js:4891 keeps a turn only if it fits, newest not forced) but the reserved note still lands.
    const ctx = Ctx{ .char = "Rita" };
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "an old line", .role = .user },
        .{ .name = "Rita", .mes = "a new line", .role = .assistant },
    };
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = "" } },
        .note = .{ .prompt = "Keep it short.", .interval = 1, .position = .in_chat, .depth = 0, .role = .system },
    };
    const out = try buildPromptBudgeted(testing.allocator, ctx, &history, 20, shape, null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Keep it short.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "an old line") == null);
    try testing.expect(std.mem.indexOf(u8, out, "a new line") == null);
}

test "an empty windowed history ships no continuation cue" {
    // Story block alone exceeds the budget -> whole history drops -> no cue (classic modifyLastPromptLine
    // runs only for a non-empty history, script.js:4994). Non-empty path still primes, per other tests.
    const ctx = Ctx{ .char = "Rita", .description = "A long diver biography that will not fit." };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "Hi.", .role = .user }};
    const shape = Shape{ .tpl = .{ .context = .{ .story_string = templates.default_story_string } } };
    const out = try buildPromptBudgeted(testing.allocator, ctx, &history, 5, shape, null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Hi.") == null); // history dropped
    try testing.expect(!std.mem.endsWith(u8, out, "Rita:")); // no continuation cue
    try testing.expectEqualStrings("A long diver biography that will not fit.\n", out);
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

fn wiTestEntry(uid: i64, position: @import("./world_info.zig").Position, content: []const u8) wi_engine.Entry {
    return .{
        .uid_key = "",
        .uid = uid,
        .keys = &.{},
        .keysecondary = &.{},
        .selective_logic = .and_any,
        .content = content,
        .comment = "",
        .constant = true,
        .selective = false,
        .disable = false,
        .order = 100,
        .position = position,
        .depth = 4,
        .probability = 100,
        .use_probability = true,
        .outlet_name = "",
    };
}

test "activated world info renders through the story string's wi slots" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .scenario = "the shoals" };
    var before = wiTestEntry(0, .before, "The realm of {{char}}.");
    before.constant = false;
    before.keys = &.{"realm"};
    const entries = [_]wi_engine.Entry{ before, wiTestEntry(1, .after, "WI-AFTER") };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "tell me of the realm", .role = .user }};
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = templates.default_story_string } },
        .wi_entries = &entries,
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    const want =
        "The realm of Rita.\n" ++
        "A diver.\n" ++
        "the shoals\n" ++
        "WI-AFTER\n" ++
        "Jamie: tell me of the realm\n" ++
        "Rita:";
    try testing.expectEqualStrings(want, out);
}

test "a non-matching wi entry stays out of the prompt" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver." };
    var e = wiTestEntry(0, .before, "NEVER");
    e.constant = false;
    e.keys = &.{"zebra"};
    const entries = [_]wi_engine.Entry{e};
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "hello there", .role = .user }};
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = templates.default_story_string } },
        .wi_entries = &entries,
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "NEVER") == null);
}

test "outlet entries render at their named outlet macros in the story string" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver." };
    var j_late = wiTestEntry(0, .outlet, "J-LATE for {{char}}");
    j_late.outlet_name = "judge";
    j_late.order = 200;
    var j_early = wiTestEntry(1, .outlet, "J-EARLY");
    j_early.outlet_name = "judge";
    var narrator = wiTestEntry(2, .outlet, "N-VOICE");
    narrator.outlet_name = "narrator";
    const entries = [_]wi_engine.Entry{ j_late, j_early, narrator };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "hello", .role = .user }};
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = "{{#if description}}{{description}}\n{{/if}}{{outlet::narrator}}\n{{outlet::judge}}\n{{outlet::unfed}}{{trim}}" } },
        .wi_entries = &entries,
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    // Outlet content is push over the descending scan (:5133), so the order-200 J-LATE leads J-EARLY.
    const want =
        "A diver.\n" ++
        "N-VOICE\n" ++
        "J-LATE for Rita\nJ-EARLY\n" ++
        "Jamie: hello\n" ++
        "Rita:";
    try testing.expectEqualStrings(want, out);
}

test "outlet entries drop without their macro and a nameless outlet entry always drops" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver." };
    var named = wiTestEntry(0, .outlet, "OUT-NEVER");
    named.outlet_name = "judge";
    const nameless = wiTestEntry(1, .outlet, "OUT-NAMELESS");
    const entries = [_]wi_engine.Entry{ named, nameless };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "hello", .role = .user }};
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = templates.default_story_string } },
        .wi_entries = &entries,
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "OUT-NEVER") == null);
    try testing.expect(std.mem.indexOf(u8, out, "OUT-NAMELESS") == null);
    try testing.expect(std.mem.indexOf(u8, out, "A diver.") != null);
}

test "an atDepth entry injects at its depth and survives a tight budget" {
    const ctx = Ctx{ .char = "Rita" };
    var deep = wiTestEntry(0, .at_depth, "THE WARD HOLDS");
    deep.depth = 1;
    const entries = [_]wi_engine.Entry{deep};
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "an old line", .role = .user },
        .{ .name = "Rita", .mes = "a mid line", .role = .assistant },
        .{ .name = "Jamie", .mes = "a new line", .role = .user },
    };
    const shape = Shape{ .tpl = .{ .context = .{ .story_string = "" } }, .wi_entries = &entries };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Jamie: an old line\nRita: a mid line\n: THE WARD HOLDS\nJamie: a new line\nRita:", out);

    const tight = try buildPromptBudgeted(testing.allocator, ctx, &history, 40, shape, null);
    defer testing.allocator.free(tight);
    try testing.expect(std.mem.indexOf(u8, tight, "THE WARD HOLDS") != null);
    try testing.expect(std.mem.indexOf(u8, tight, "an old line") == null);
}

test "the wi budget caps the wi slice while the story string stays uncapped" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver." };
    var hi = wiTestEntry(0, .before, "KEEPKEEPKEEP");
    hi.order = 900;
    var lo = wiTestEntry(1, .before, "DROPDROPDROP");
    lo.order = 10;
    const entries = [_]wi_engine.Entry{ hi, lo };
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = templates.default_story_string } },
        .wi_entries = &entries,
        .wi_budget_chars = 20,
    };
    const out = try buildPrompt(testing.allocator, ctx, &.{}, shape);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "KEEPKEEPKEEP") != null);
    try testing.expect(std.mem.indexOf(u8, out, "DROPDROPDROP") == null);
    try testing.expect(std.mem.indexOf(u8, out, "A diver.") != null);
}

test "an-anchored wi wraps the note's anchor slot" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .anchor_before = "NOTE" };
    const entries = [_]wi_engine.Entry{ wiTestEntry(0, .an_top, "TOP"), wiTestEntry(1, .an_bottom, "BOTTOM") };
    const story = "{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}";
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = story } },
        .note = .{ .prompt = "NOTE", .interval = 1, .position = .before_prompt },
        .wi_entries = &entries,
    };
    const out = try buildPrompt(testing.allocator, ctx, &.{}, shape);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("TOP\nNOTE\nBOTTOM\nA diver.\nRita:", out);
}

test "persona TOP_AN and BOTTOM_AN wrap OUTSIDE the wi an-anchors on the note slot" {
    const entries = [_]wi_engine.Entry{ wiTestEntry(0, .an_top, "TOP"), wiTestEntry(1, .an_bottom, "BOTTOM") };
    const story = "{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}";
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .anchor_before = "NOTE", .persona = "PERSONA" };
    const base = Shape{
        .tpl = .{ .context = .{ .story_string = story } },
        .note = .{ .prompt = "NOTE", .interval = 1, .position = .before_prompt },
        .wi_entries = &entries,
    };

    var top = base;
    top.persona_position = .top_an;
    const out_top = try buildPrompt(testing.allocator, ctx, &.{}, top);
    defer testing.allocator.free(out_top);
    try testing.expectEqualStrings("PERSONA\nTOP\nNOTE\nBOTTOM\nA diver.\nRita:", out_top);

    var bot = base;
    bot.persona_position = .bottom_an;
    const out_bot = try buildPrompt(testing.allocator, ctx, &.{}, bot);
    defer testing.allocator.free(out_bot);
    try testing.expectEqualStrings("TOP\nNOTE\nBOTTOM\nPERSONA\nA diver.\nRita:", out_bot);
}

test "an empty note between two wi an-anchors keeps stock's blank line" {
    const entries = [_]wi_engine.Entry{ wiTestEntry(0, .an_top, "TOP"), wiTestEntry(1, .an_bottom, "BOTTOM") };
    const story = "{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}";
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .persona = "PERSONA" };
    const base = Shape{
        .tpl = .{ .context = .{ .story_string = story } },
        .note = .{ .prompt = "", .interval = 1, .position = .before_prompt },
        .wi_entries = &entries,
    };

    // Stock's `${top}\n${note}\n${bottom}` leaves a blank line when the note is empty (world-info.js:5149).
    const plain = try buildPrompt(testing.allocator, ctx, &.{}, base);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("TOP\n\nBOTTOM\nA diver.\nRita:", plain);

    var top = base;
    top.persona_position = .bottom_an;
    const out = try buildPrompt(testing.allocator, ctx, &.{}, top);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("TOP\n\nBOTTOM\nPERSONA\nA diver.\nRita:", out);
}

test "resolveAnchorBlock seeds a note {{pick}} off the wrapped block, not the bare note" {
    const rng = @import("./rng.zig");
    const chat_id = "Chat_2024-01-15@10h30m";
    const an_top = "WI-9302 lore entry 9302";
    const note = "AN the wind rises {{pick::one,two,three}} tail";
    const out = (try resolveAnchorBlock(testing.allocator, &.{ an_top, note, "" }, .{ .chat_id = chat_id })).?;
    defer testing.allocator.free(out);

    // Stock seeds the pick off the wrapped getExtensionPrompt block and its offset inside it, not off
    // the bare note. Rebuild that block and offset here; the resolved word must match.
    const wrapped = try std.fmt.allocPrint(testing.allocator, "\n{s}\n{s}\n", .{ an_top, note });
    defer testing.allocator.free(wrapped);
    const words = [_][]const u8{ "one", "two", "three" };
    const want = words[rng.pickIndex(chat_id, wrapped, std.mem.indexOf(u8, wrapped, "{{pick").?, words.len)];
    const expect = try std.fmt.allocPrint(testing.allocator, "WI-9302 lore entry 9302\nAN the wind rises {s} tail", .{want});
    defer testing.allocator.free(expect);
    try testing.expectEqualStrings(expect, out);
}

test "resolveAnchorBlock trims the block and returns null for an all-empty set" {
    const trimmed = (try resolveAnchorBlock(testing.allocator, &.{ "  \n", "  hi  ", "" }, .{})).?;
    defer testing.allocator.free(trimmed);
    try testing.expectEqualStrings("hi", trimmed);
    try testing.expectEqual(@as(?[]u8, null), try resolveAnchorBlock(testing.allocator, &.{ "", "  ", "\n\t" }, .{}));
}

test "an-position wi fires the in-chat note slot even when the note is silent" {
    const ctx = Ctx{ .char = "Rita" };
    var top = wiTestEntry(0, .an_top, "TOP");
    top.depth = 0;
    const entries = [_]wi_engine.Entry{top};
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "one", .role = .user }};
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = "" } },
        .note = .{ .prompt = "", .interval = 1, .position = .in_chat, .depth = 0, .role = .system },
        .wi_entries = &entries,
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Jamie: one\n: TOP\nRita:", out);
}

test "em entries bracket the example blocks under the separator" {
    const ctx = Ctx{ .char = "Rita", .mes_example = "<START>\nRita: card" };
    const entries = [_]wi_engine.Entry{ wiTestEntry(0, .em_top, "EM-TOP"), wiTestEntry(1, .em_bottom, "EM-BOTTOM") };
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = "", .example_separator = "***" } },
        .wi_entries = &entries,
    };
    const out = try buildPrompt(testing.allocator, ctx, &.{}, shape);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("***\nEM-TOP\n***\nRita: card\n***\nEM-BOTTOM\nRita:", out);
}

test "buildPromptBudgeted cleans up on every allocation failure" {
    const ctx = Ctx{ .char = "Rita", .description = "A diver.", .system = "You are {{char}}." };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, c: Ctx) !void {
            const history = [_]PromptMsg{
                .{ .name = "Jamie", .mes = "Hi.", .role = .user },
                .{ .name = "Rita", .mes = "Hello.", .role = .assistant },
            };
            var keyed = wiTestEntry(0, .before, "of {{char}}");
            keyed.constant = false;
            keyed.keys = &.{"hi"};
            const entries = [_]wi_engine.Entry{ keyed, wiTestEntry(1, .at_depth, "WARD"), wiTestEntry(2, .em_top, "EM") };
            const shape = Shape{
                .tpl = .{ .instruct = chatml, .context = .{ .story_string = templates.default_story_string, .example_separator = "***" } },
                .note = .{ .prompt = "Be terse.", .interval = 1, .position = .in_chat, .depth = 1, .role = .system },
                .wi_entries = &entries,
            };
            const out = try buildPromptBudgeted(alloc, c, &history, 4096, shape, null);
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

fn freeStops(a: Allocator, stops: [][]u8) void {
    for (stops) |s| a.free(s);
    a.free(stops);
}

fn expectStops(want: []const []const u8, got: [][]u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "buildStoppingStrings matches the classic frontend for the ChatML instruct path" {
    const tpl = templates.Templates{
        .instruct = chatml,
        .context = .{ .names_as_stop_strings = true, .use_stop_strings = false },
        .custom_stopping_strings = "[\"ZSTOP_A\",\"ZSTOP_B\"]",
        .custom_stopping_strings_macro = true,
    };
    const ctx = Ctx{ .char = "Seraphina", .user = "Tester" };
    const stops = try buildStoppingStrings(testing.allocator, tpl, ctx, "Tester", "Seraphina");
    defer freeStops(testing.allocator, stops);
    try expectStops(&.{
        "\nTester:",
        "\n<|im_end|>",
        "\n<|im_start|>user",
        "\n<|im_start|>assistant",
        "\n<|im_start|>system",
        "ZSTOP_A",
        "ZSTOP_B",
    }, stops);
}

test "buildStoppingStrings unwraps sequences and prepends single_line" {
    var ins = chatml;
    ins.wrap = false;
    const tpl = templates.Templates{
        .instruct = ins,
        .context = .{ .names_as_stop_strings = false },
        .single_line = true,
    };
    const stops = try buildStoppingStrings(testing.allocator, tpl, .{ .char = "Bob" }, "Alice", "Bob");
    defer freeStops(testing.allocator, stops);
    try expectStops(&.{
        "\n",
        "<|im_end|>",
        "<|im_start|>user",
        "<|im_start|>assistant",
        "<|im_start|>system",
    }, stops);
}

test "buildStoppingStrings appends chat_start and example_separator when use_stop_strings" {
    const tpl = templates.Templates{
        .instruct = .{ .enabled = true, .stop_sequence = "<|im_end|>", .wrap = true, .sequences_as_stop_strings = false },
        .context = .{ .names_as_stop_strings = false, .use_stop_strings = true, .chat_start = "***", .example_separator = "<START>" },
    };
    const stops = try buildStoppingStrings(testing.allocator, tpl, .{}, "Alice", "Bob");
    defer freeStops(testing.allocator, stops);
    try expectStops(&.{ "\n<|im_end|>", "\n***", "\n<START>" }, stops);
}

test "buildStoppingStrings resolves the name token per sequence family" {
    const tpl = templates.Templates{
        .instruct = .{
            .enabled = true,
            .input_sequence = "{{name}}:",
            .output_sequence = "{{Name}}:",
            .wrap = false,
            .macro = false,
            .sequences_as_stop_strings = true,
        },
        .context = .{ .names_as_stop_strings = false },
    };
    const stops = try buildStoppingStrings(testing.allocator, tpl, .{}, "Alice", "Bob");
    defer freeStops(testing.allocator, stops);
    try expectStops(&.{ "Alice:", "Bob:" }, stops);
}

test "buildStoppingStrings drops the instruct set entirely when disabled" {
    const tpl = templates.Templates{
        .instruct = .{ .enabled = false, .stop_sequence = "<|im_end|>" },
        .context = .{ .names_as_stop_strings = true },
    };
    const stops = try buildStoppingStrings(testing.allocator, tpl, .{}, "Alice", "Bob");
    defer freeStops(testing.allocator, stops);
    try expectStops(&.{"\nAlice:"}, stops);
}

fn buildStoppingStringsAndFree(a: Allocator, tpl: templates.Templates, ctx: Ctx, name1: []const u8, name2: []const u8) Allocator.Error!void {
    const stops = try buildStoppingStrings(a, tpl, ctx, name1, name2);
    freeStops(a, stops);
}

test "buildStoppingStrings cleans up on every alloc failure" {
    const tpl = templates.Templates{
        .instruct = chatml,
        .context = .{ .names_as_stop_strings = true, .use_stop_strings = true, .chat_start = "***", .example_separator = "<START>" },
        .custom_stopping_strings = "[\"ZSTOP_A\",\"ZSTOP_B\"]",
        .custom_stopping_strings_macro = true,
        .single_line = true,
    };
    const ctx = Ctx{ .char = "Seraphina", .user = "Tester" };
    try testing.checkAllAllocationFailures(testing.allocator, buildStoppingStringsAndFree, .{ tpl, ctx, @as([]const u8, "Tester"), @as([]const u8, "Seraphina") });
}

test "buildRequestBody carries the connection, prompt, and stream flag" {
    const conn = Connection{
        .api_type = try testing.allocator.dupe(u8, "llamacpp"),
        .api_server = try testing.allocator.dupe(u8, "http://127.0.0.1:8080"),
        .model = try testing.allocator.dupe(u8, ""),
        .token_padding = 0,
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
        .model = try testing.allocator.dupe(u8, ""),
        .token_padding = 0,
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

test "buildPrompt fills the story persona slot for IN_PROMPT and AFTER_CHAR" {
    const ctx = Ctx{ .char = "Rita", .persona = "Jamie dives too." };
    const in_prompt = try buildPrompt(testing.allocator, ctx, &.{}, .{ .persona_position = .in_prompt });
    defer testing.allocator.free(in_prompt);
    try testing.expect(std.mem.indexOf(u8, in_prompt, "Jamie dives too.") != null);
    const after_char = try buildPrompt(testing.allocator, ctx, &.{}, .{ .persona_position = .after_char });
    defer testing.allocator.free(after_char);
    try testing.expect(std.mem.indexOf(u8, after_char, "Jamie dives too.") != null);
}

test "buildPrompt empties the story persona slot for NONE, TOP_AN, and BOTTOM_AN" {
    const ctx = Ctx{ .char = "Rita", .persona = "Jamie dives too." };
    for ([_]templates.PersonaPosition{ .none, .top_an, .bottom_an }) |pos| {
        // Note disabled (interval 0) so the persona cannot ride the author's-note slot; its only other
        // home is the story {{persona}} slot, which fillsStory() empties for these three positions.
        const out = try buildPrompt(testing.allocator, ctx, &.{}, .{ .persona_position = pos, .note = .{ .interval = 0 } });
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "Jamie dives too.") == null);
    }
}

test "buildPrompt injects the persona in-chat for AT_DEPTH at its depth and role" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie", .persona = "PERSONA_MARK" };
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "Hi.", .role = .user },
        .{ .name = "Rita", .mes = "Hello.", .role = .assistant },
    };
    var shape = chatmlShape();
    shape.persona_position = .at_depth;
    shape.persona_depth = 1;
    shape.persona_role = 1;
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    const persona_at = std.mem.indexOf(u8, out, "PERSONA_MARK") orelse return error.PersonaMissing;
    const first_at = std.mem.indexOf(u8, out, "Hi.").?;
    const newest_at = std.mem.indexOf(u8, out, "Hello.").?;
    try testing.expect(persona_at > first_at and persona_at < newest_at);
    try testing.expect(std.mem.indexOf(u8, out, "<|im_start|>user\nPERSONA_MARK") != null);
}

test "buildPrompt injects nothing for AT_DEPTH with an empty persona" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie", .persona = "" };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "Hi.", .role = .user }};
    var shape = chatmlShape();
    shape.persona_position = .at_depth;
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Hi.") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "<|im_start|>user"));
}

test "buildPrompt emits shared-depth injections in assistant, user, system order" {
    const ctx = Ctx{ .char = "Rita" };
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "one", .role = .user },
        .{ .name = "Rita", .mes = "two", .role = .assistant },
    };
    var shape = chatmlShape();
    shape.tpl.context.story_string = "";
    shape.note = .{ .prompt = "SYS_NOTE", .interval = 1, .position = .in_chat, .depth = 1, .role = .system };
    shape.char_note = .{ .prompt = "ASST_NOTE", .depth = 1, .role = .assistant };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    const asst = std.mem.indexOf(u8, out, "ASST_NOTE") orelse return error.NoAsst;
    const sys = std.mem.indexOf(u8, out, "SYS_NOTE") orelse return error.NoSys;
    try testing.expect(asst < sys);
    try testing.expect(std.mem.indexOf(u8, out, "<|im_start|>assistant\nASST_NOTE") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<|im_start|>system\nSYS_NOTE") != null);
}

test "buildPrompt joins same-depth same-role injections into one turn" {
    const ctx = Ctx{ .char = "Rita", .persona = "PERSONA_MARK" };
    const history = [_]PromptMsg{
        .{ .name = "Jamie", .mes = "one", .role = .user },
        .{ .name = "Rita", .mes = "two", .role = .assistant },
    };
    var shape = chatmlShape();
    shape.tpl.context.story_string = "";
    shape.note = .{ .prompt = "SYS_NOTE", .interval = 1, .position = .in_chat, .depth = 1, .role = .system };
    shape.persona_position = .at_depth;
    shape.persona_depth = 1;
    shape.persona_role = 0;
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<|im_start|>system\nSYS_NOTE\nPERSONA_MARK<|im_end|>") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "<|im_start|>system"));
}

test "buildPrompt trims injection value whitespace, matching stock getExtensionPrompt" {
    const ctx = Ctx{ .char = "Rita" };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "one", .role = .user }};
    var shape = chatmlShape();
    shape.tpl.context.story_string = "";
    shape.char_note = .{ .prompt = "note with trailing ", .depth = 0, .role = .system };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    // Stock trims each value both ends before wrapping (script.js:3286); the old note here kept the
    // trailing space, which diverged from the old frontend by one byte.
    try testing.expect(std.mem.indexOf(u8, out, "<|im_start|>system\nnote with trailing<|im_end|>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "trailing <|im_end|>") == null);
}

test "groupInjections joins same-depth values then resolves {{pick}} off the whole block" {
    const mctx = Ctx{ .chat_id = "room-7", .user = "U", .char = "C" };
    const t0 = try testing.allocator.dupe(u8, "prefix line");
    defer testing.allocator.free(t0);
    const t1 = try testing.allocator.dupe(u8, "{{pick::a::b::c::d::e}}");
    defer testing.allocator.free(t1);
    const contribs = [_]Contribution{
        .{ .depth = 0, .role = .system, .text = t0 },
        .{ .depth = 0, .role = .system, .text = t1 },
    };
    const tpl = templates.Instruct{ .enabled = true, .system_sequence = "<sys>", .system_suffix = "<end>", .wrap = false, .names_behavior = .none };
    var out: std.ArrayList(AssembledInjection) = .empty;
    defer {
        for (out.items) |x| testing.allocator.free(x.wrapped);
        out.deinit(testing.allocator);
    }
    try groupInjections(testing.allocator, &out, tpl, &contribs, mctx);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    // The pick must seed off the JOINED+trimmed block "prefix line\n{{pick...}}" (offset 12), which is
    // what substituteMacros over that same block yields. Resolving t1 alone (offset 0) would differ.
    const block_resolved = try substituteMacros(testing.allocator, "prefix line\n{{pick::a::b::c::d::e}}", mctx);
    defer testing.allocator.free(block_resolved);
    const want = try std.fmt.allocPrint(testing.allocator, "<sys>{s}<end>", .{block_resolved});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, out.items[0].wrapped);
}

test "buildPrompt names a user-role depth injection like a user turn" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie" };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "hi", .role = .user }};
    const shape = Shape{
        .tpl = .{ .context = .{ .story_string = "" } },
        .char_note = .{ .prompt = "USER_NOTE", .depth = 0, .role = .user },
    };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Jamie: USER_NOTE") != null);
}

test "buildPrompt keeps deeper clamped injections before shallower at the head" {
    const ctx = Ctx{ .char = "Rita", .user = "Jamie" };
    const history = [_]PromptMsg{.{ .name = "Jamie", .mes = "hi", .role = .user }};
    var shape = chatmlShape();
    shape.tpl.context.story_string = "";
    shape.note = .{ .prompt = "DEEPNOTE", .interval = 1, .position = .in_chat, .depth = 5, .role = .system };
    shape.char_note = .{ .prompt = "SHALLOWNOTE", .depth = 3, .role = .user };
    const out = try buildPrompt(testing.allocator, ctx, &history, shape);
    defer testing.allocator.free(out);
    const deep = std.mem.indexOf(u8, out, "DEEPNOTE") orelse return error.NoDeep;
    const shallow = std.mem.indexOf(u8, out, "SHALLOWNOTE") orelse return error.NoShallow;
    try testing.expect(deep < shallow);
}
