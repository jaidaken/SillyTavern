//! A second host for the pure prompt builder: a wasm module with no ziex, no DOM and no host
//! imports, so a Node server can assemble the same prompt the browser assembles instead of paying a
//! round trip per token count.
//!
//! The ABI is four exports over one internal allocator. `alloc`/`free` move utf8 JSON across the
//! boundary; `pieces` and `fit` each take a request document and return a packed pointer+length
//! (pointer in the high 32 bits, length in the low 32) pointing at utf8 JSON the host frees with
//! `free`. Malformed input answers with a JSON object carrying an `error` string; nothing traps and
//! no state survives a call, so a bad request cannot wedge the module.
//!
//! Nothing here re-implements the builder. The request is mapped onto the existing `generate.Ctx`
//! and `generate.Shape` exactly as `cast/char_api.zig` maps the browser's state onto them, and the
//! existing parsers do the reading: `templates.parseTemplates` for the formatting templates,
//! `authors_note.parse` for the chat note, `WorldInfoStore.setFromSettings` + `collectActive` for
//! the lore, `world_info_engine.readTimedFromMetadata` for the timed-effect state.

const std = @import("std");
const builtin = @import("builtin");

const generate = @import("./pages/setup/generate.zig");
const templates = @import("./pages/setup/templates.zig");
const authors_note = @import("./pages/setup/authors_note.zig");
const macro_chat = @import("./pages/setup/macro_chat.zig");
const wi = @import("./pages/setup/world_info.zig");
const wi_engine = @import("./pages/setup/world_info_engine.zig");
const char_data = @import("./pages/cast/char_data.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// The service has no console. std's default log handler reaches for a threaded Io that does not
/// exist on wasm32-freestanding, so the builder's warnings are dropped here; everything the host
/// must act on rides the JSON answer instead.
pub const std_options: std.Options = .{ .logFn = discardLog };

fn discardLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// The module's own heap. wasm grows linear memory; a native test build (the inline tests below run
/// natively) never reaches the exports and uses this only if something calls them directly.
const host_gpa: Allocator = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;

/// Returned by `alloc` for a zero-length request and for an allocation the module could not serve.
/// `free` recognises it and does nothing, so a host that frees every pointer it received is safe.
var alloc_sentinel: [1]u8 = .{0};

/// The one answer the module can give when even the error string will not allocate. Static, so
/// `free` must not hand it to the allocator either.
const oom_json = "{\"error\":\"OutOfMemory\"}";

/// Reserve `len` bytes of module memory for the host to write a request into. The sentinel pointer
/// comes back for a zero-length or unservable request.
export fn alloc(len: usize) [*]u8 {
    if (len == 0) return &alloc_sentinel;
    const buf = host_gpa.alloc(u8, len) catch return &alloc_sentinel;
    return buf.ptr;
}

/// Release a buffer obtained from `alloc`, or a result buffer returned by `pieces`/`fit`. `len` must
/// be the length the host was given.
export fn free(ptr: [*]u8, len: usize) void {
    if (len == 0) return;
    const addr = @intFromPtr(ptr);
    if (addr == @intFromPtr(&alloc_sentinel) or addr == @intFromPtr(oom_json.ptr)) return;
    host_gpa.free(ptr[0..len]);
}

/// Assemble the prompt into separately-costable pieces. Returns `{pieces, stop, timed, reply_prefix}`
/// packed as pointer+length; the host tokenizes each piece text and calls `fit` with the counts.
export fn pieces(ptr: [*]const u8, len: usize) u64 {
    const out = piecesJson(host_gpa, ptr[0..len]) catch return packConst(oom_json);
    return pack(out);
}

/// The lore texts the budget will spend, so the host can count their tokens and hand them back on the
/// `pieces` call. Same packed shape as every other entry point.
export fn entries(ptr: [*]const u8, len: usize) u64 {
    const out = entriesJson(host_gpa, ptr[0..len]) catch return packConst(oom_json);
    return pack(out);
}

/// Walk the budget over the same request plus a `costs` array parallel to the pieces, and return
/// `{prompt}` packed as pointer+length.
export fn fit(ptr: [*]const u8, len: usize) u64 {
    const out = fitJson(host_gpa, ptr[0..len]) catch return packConst(oom_json);
    return pack(out);
}

/// Pointer in the high 32 bits, length in the low 32. The encoding assumes the wasm32 address space;
/// the exports are never called from a native build.
fn pack(s: []const u8) u64 {
    return (@as(u64, @intCast(@intFromPtr(s.ptr))) << 32) | @as(u64, @intCast(s.len));
}

fn packConst(s: []const u8) u64 {
    return pack(s);
}

// ---- the two request paths --------------------------------------------------------------------

/// Every failure that answers with an `error` object rather than a trap. `OutOfMemory` is NOT one of
/// them: it propagates so the alloc-failure oracle sees an unswallowed OOM.
const RequestError = error{
    NotAnObject,
    NoCostsArray,
    CostArityMismatch,
} || generate.ConnectionError;

pub fn piecesJson(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = piecesBody(a, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorJson(gpa, @errorName(err)),
    };
    return gpa.dupe(u8, body);
}

pub fn fitJson(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = fitBody(a, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorJson(gpa, @errorName(err)),
    };
    return gpa.dupe(u8, body);
}

fn errorJson(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{ .@"error" = name }, .{});
}

/// The world-info store for a request, hydrated the same way for every entry point so `entries` and
/// `pieces` can never disagree about which lore is in play.
fn loadStore(a: Allocator, doc: std.json.ObjectMap, settings_str: []const u8) RequestError!wi.WorldInfoStore {
    var store = wi.WorldInfoStore.init(a);
    store.setFromSettings(settings_str);
    if (doc.get("world")) |world| if (world == .object) {
        const book = try std.json.Stringify.valueAlloc(a, world, .{});
        // A book the request could not express (no `entries` object) yields no lore rather than
        // failing the whole send, matching how the browser degrades a bad book file.
        store.loadBookFromJson(request_book_id, book) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        _ = store.toggleGlobal(request_book_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    };
    return store;
}

/// The candidate lore for a request, in the order the budget will spend it.
fn candidates(a: Allocator, doc: std.json.ObjectMap) RequestError![]const wi.Entry {
    const settings_str = try jsonText(a, doc.get("settings"));
    var store = try loadStore(a, doc, settings_str);
    return store.collectActive(a);
}

pub fn entriesJson(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = entriesBody(a, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorJson(gpa, @errorName(err)),
    };
    return gpa.dupe(u8, body);
}

/// The candidate lore texts in activation order, each already carrying the newline stock joins entries
/// with, so the count the host hands back is the exact cost the budget spends.
fn entriesBody(a: Allocator, input: []const u8) RequestError![]u8 {
    const doc = try parseDoc(a, input);
    const cand = try candidates(a, doc);
    var list = std.json.Array.init(a);
    for (cand) |e| list.append(.{ .string = try std.fmt.allocPrint(a, "{s}\n", .{e.content}) }) catch return error.OutOfMemory;
    var root: std.json.ObjectMap = .empty;
    try root.put(a, "entries", .{ .array = list });
    return std.json.Stringify.valueAlloc(a, Value{ .object = root }, .{});
}

fn piecesBody(a: Allocator, input: []const u8) RequestError![]u8 {
    const doc = try parseDoc(a, input);
    const built = try build(a, doc);
    const p = built.pieces;

    var list = std.json.Array.init(a);
    try list.append(try pieceValue(a, "overhead", p.overhead));
    try list.append(try pieceValue(a, "alignment", p.alignment));
    for (p.injections) |inj| try list.append(try pieceValue(a, "injection", inj.wrapped));
    for (p.wrapped_history) |w| try list.append(try pieceValue(a, "history", w));

    var stops = std.json.Array.init(a);
    for (built.stop) |s| try stops.append(.{ .string = s });

    var root: std.json.ObjectMap = .empty;
    try root.put(a, "pieces", .{ .array = list });
    try root.put(a, "stop", .{ .array = stops });
    try root.put(a, "timed", try timedValue(a, p.timed_json));
    try root.put(a, "reply_prefix", .{ .string = p.prefix });
    return std.json.Stringify.valueAlloc(a, Value{ .object = root }, .{});
}

fn fitBody(a: Allocator, input: []const u8) RequestError![]u8 {
    const doc = try parseDoc(a, input);
    const costs_v = doc.get("costs") orelse return error.NoCostsArray;
    if (costs_v != .array) return error.NoCostsArray;
    const built = try build(a, doc);
    const p = built.pieces;

    // Costs are parallel to the pieces array: overhead, alignment, one per injection, one per turn.
    // The alignment cost folds into the reserved overhead, matching generate.byteCostTable.
    const want = 2 + p.injections.len + p.wrapped_history.len;
    if (costs_v.array.items.len != want) return error.CostArityMismatch;
    const raw = try a.alloc(usize, want);
    for (costs_v.array.items, 0..) |c, i| raw[i] = costUnit(c);

    const table = generate.CostTable{
        .overhead = raw[0] +| raw[1],
        .injections = raw[2 .. 2 + p.injections.len],
        .history = raw[2 + p.injections.len ..],
    };
    const prompt = try generate.fitAndAssemble(a, p, table, generate.promptTokenBudget(built.conn));

    var root: std.json.ObjectMap = .empty;
    try root.put(a, "prompt", .{ .string = prompt });
    return std.json.Stringify.valueAlloc(a, Value{ .object = root }, .{});
}

fn pieceValue(a: Allocator, kind: []const u8, text: []const u8) Allocator.Error!Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "kind", .{ .string = kind });
    try o.put(a, "text", .{ .string = text });
    return .{ .object = o };
}

fn timedValue(a: Allocator, timed_json: ?[]const u8) Allocator.Error!Value {
    const raw = timed_json orelse return .{ .object = .empty };
    if (raw.len == 0) return .{ .object = .empty };
    return std.json.parseFromSliceLeaky(Value, a, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => Value{ .object = .empty },
    };
}

fn costUnit(v: Value) usize {
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |f| if (f > 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn parseDoc(a: Allocator, input: []const u8) RequestError!std.json.ObjectMap {
    const root = std.json.parseFromSliceLeaky(Value, a, input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseFailed,
    };
    return switch (root) {
        .object => |o| o,
        else => error.NotAnObject,
    };
}

// ---- the request -> Ctx/Shape mapping (mirrors cast/char_api.zig dispatchGenerate) -------------

const Built = struct {
    pieces: generate.Pieces,
    stop: [][]u8,
    conn: generate.Connection,
};

/// Everything is arena-owned, so nothing here frees: the caller drops the arena. World info
/// activates inside `assemblePieces` exactly as it does on the browser path.
fn build(a: Allocator, doc: std.json.ObjectMap) RequestError!Built {
    const settings_str = try jsonText(a, doc.get("settings"));
    const conn = try generate.extractConnection(a, settings_str);
    const tpl = try templates.parseTemplates(a, settings_str);

    const meta_str = try jsonText(a, doc.get("chat_metadata"));
    const meta = try asObjectValue(a, doc.get("chat_metadata"));
    const note = authors_note.parse(meta);

    const card = try asObjectValue(a, doc.get("card"));
    const card_obj: std.json.ObjectMap = switch (card) {
        .object => |o| o,
        else => .empty,
    };
    const char_name = cardDataStr(&card_obj, "name");
    const description = cardDataStr(&card_obj, "description");
    const personality = cardDataStr(&card_obj, "personality");
    const scenario = cardDataStr(&card_obj, "scenario");
    const mes_example = cardDataStr(&card_obj, "mes_example");
    const first_mes = cardDataStr(&card_obj, "first_mes");
    const card_system = cardDataStr(&card_obj, "system_prompt");
    const card_post_history = cardDataStr(&card_obj, "post_history_instructions");
    const creator_notes = cardDataStr(&card_obj, "creator_notes");
    const char_version = cardDataStr(&card_obj, "character_version");
    const depth_prompt = cardDepthPrompt(&card_obj);
    const alt_greetings = try cardAltGreetings(a, &card_obj);

    const persona = try activePersona(a, settings_str);

    const chat = try asObjectValue(a, doc.get("chat"));
    const chat_obj: std.json.ObjectMap = switch (chat) {
        .object => |o| o,
        else => .empty,
    };
    const chat_file = strOf(chat_obj.get("file_name"));
    const chat_avatar = strOf(chat_obj.get("avatar_url"));

    const browser = try asObjectValue(a, doc.get("browser"));
    const browser_obj: std.json.ObjectMap = switch (browser) {
        .object => |o| o,
        else => .empty,
    };
    const user_input = strOf(browser_obj.get("input"));
    const generation_type = if (strOf(browser_obj.get("generation_type")).len > 0)
        strOf(browser_obj.get("generation_type"))
    else
        "normal";
    const rotation_index = intOf(browser_obj.get("rotation_index"), 0);

    var history: std.ArrayList(generate.PromptMsg) = .empty;
    var chat_msgs: std.ArrayList(macro_chat.Msg) = .empty;
    if (doc.get("messages")) |msgs| if (msgs == .array) {
        for (msgs.array.items) |m| {
            if (m != .object) continue;
            const o = m.object;
            const is_user = boolOf(o.get("is_user"), false);
            const is_system = boolOf(o.get("is_system"), false);
            const raw_name = strOf(o.get("name"));
            const name = if (raw_name.len > 0) raw_name else if (is_user) persona.name else char_name;
            const mes = strOf(o.get("mes"));
            const role: templates.Role = if (is_system) .system else if (is_user) .user else .assistant;
            try history.append(a, .{ .name = name, .mes = mes, .role = role });
            try chat_msgs.append(a, .{ .name = name, .mes = mes, .is_user = is_user, .is_system = is_system });
        }
    };

    var store = try loadStore(a, doc, settings_str);
    const wi_entries = try store.collectActive(a);

    // Stock counts the lore budget in TOKENS on both halves (world-info.js:4622 and :4624). The host
    // gets those counts from the `entries` call and hands them back here; without them the whole
    // budget degrades to bytes TOGETHER, because a token budget spent against byte costs is worse
    // than either unit alone (char_api.zig).
    const wi_costs: []const usize = blk: {
        const arr = doc.get("wi_entry_costs") orelse break :blk &.{};
        if (arr != .array) break :blk &.{};
        if (arr.array.items.len != wi_entries.len) break :blk &.{};
        const out = try a.alloc(usize, arr.array.items.len);
        for (arr.array.items, 0..) |v, i| out[i] = @intCast(@max(0, intOf(@as(?Value, v), 0)));
        break :blk out;
    };
    const wi_budget = blk: {
        const total = if (wi_costs.len > 0) generate.promptTokenBudget(conn) else generate.promptCharBudget(conn);
        var b = (total *| @as(usize, @intCast(@max(0, store.budget)))) / 100;
        if (store.budget_cap > 0) {
            const cap = if (wi_costs.len > 0)
                @as(usize, @intCast(store.budget_cap))
            else
                generate.tokensToChars(@intCast(store.budget_cap));
            if (b > cap) b = cap;
        }
        break :blk b;
    };

    const anchors = noteAnchors(note);
    const effective_system = generate.effectiveSystem(tpl.sysprompt_enabled, tpl.prefer_character_prompt, card_system, tpl.system_prompt);

    // `pieces` and `fit` build twice and must activate the same lore both times, so the seed cannot be
    // a clock read here. The HOST supplies one fresh seed per generation instead: identical across the
    // two calls of one send, different on the next send AND on a swipe, which is what a re-draw per
    // build means. Deriving it from the request would make a swipe reroll identically.
    const prng = try a.create(std.Random.DefaultPrng);
    const host_seed = intOf(browser_obj.get("seed"), 0);
    prng.* = std.Random.DefaultPrng.init(if (host_seed != 0)
        @bitCast(host_seed)
    else
        requestSeed(chat_file, generation_type, rotation_index, history.items.len));

    var ctx = generate.Ctx{
        .chat = .{ .messages = chat_msgs.items },
        .now_ms = intOf(browser_obj.get("now_ms"), 0),
        .utc_offset_minutes = @intCast(intOf(browser_obj.get("utc_offset_minutes"), 0)),
        .idle_ms = 0,
        .env = .{
            .model = conn.model,
            .system_prompt = effective_system,
            .input = user_input,
            .max_context = @intCast(@max(0, conn.max_context)),
            .max_prompt = generate.promptTokenBudget(conn),
            .max_response = @intCast(@max(0, conn.max_tokens)),
            .is_mobile = boolOf(browser_obj.get("is_mobile"), false),
            .last_generation_type = generation_type,
        },
        .char = char_name,
        .user = persona.name,
        .persona = persona.description,
        .description = description,
        .personality = personality,
        .scenario = scenario,
        .mes_example = mes_example,
        .char_prompt = if (tpl.prefer_character_prompt) card_system else "",
        .char_instruction = if (tpl.prefer_character_jailbreak) card_post_history else "",
        .char_depth_prompt = depth_prompt.prompt,
        .creator_notes = creator_notes,
        .first_mes = first_mes,
        .alt_greetings = alt_greetings,
        .char_version = char_version,
        .system = effective_system,
        .original = tpl.system_prompt,
        .anchor_before = anchors.before,
        .anchor_after = anchors.after,
        .chat_id = chat_file,
        .rng = prng.random(),
    };
    ctx.mes_example_formatted = try generate.renderMesExamplesMacro(a, mes_example, char_name, persona.name, tpl.instruct, tpl.context.example_separator, ctx);

    const effective_jb = generate.effectiveSystem(tpl.sysprompt_enabled, tpl.prefer_character_jailbreak, card_post_history, tpl.sysprompt_post_history);
    var jb_ctx = ctx;
    jb_ctx.original = tpl.sysprompt_post_history;
    const jailbreak: []const u8 = if (effective_jb.len > 0) try generate.substituteMacros(a, effective_jb, jb_ctx) else "";

    const shape = generate.Shape{
        .tpl = tpl,
        .note = note,
        .char_note = .{ .prompt = depth_prompt.prompt, .depth = depth_prompt.depth, .role = depth_prompt.role },
        .jailbreak = jailbreak,
        .wi_entries = wi_entries,
        .wi_entry_costs = wi_costs,
        .wi_scan_depth = @intCast(@max(0, store.scan_depth)),
        .wi_budget = wi_budget,
        .wi_recursive = store.recursive,
        .wi_max_recursion_steps = @intCast(@max(0, store.max_recursion_steps)),
        .wi_case_sensitive = store.case_sensitive,
        .wi_match_whole_words = store.match_whole_words,
        .wi_min_activations = @intCast(@max(0, store.min_activations)),
        .wi_min_activations_depth_max = @intCast(@max(0, store.min_activations_depth_max)),
        .wi_use_group_scoring = store.use_group_scoring,
        .wi_rng = prng.random(),
        .wi_timed_in = wi_engine.readTimedFromMetadata(a, meta_str),
        .wi_chara_filename = charaFilename(chat_avatar),
        .wi_char_tags = null,
        .wi_generation_trigger = generation_type,
        .wi_persona_description = persona.description,
        .wi_character_description = description,
        .wi_character_personality = personality,
        .wi_character_depth_prompt = depth_prompt.prompt,
        .wi_scenario = scenario,
        .wi_creator_notes = creator_notes,
        .persona_position = tpl.persona_position,
        .persona_depth = tpl.persona_depth,
        .persona_role = tpl.persona_role,
    };

    return .{
        .pieces = try generate.assemblePieces(a, ctx, history.items, shape, true),
        .stop = try generate.buildStoppingStrings(a, tpl, ctx, persona.name, char_name),
        .conn = conn,
    };
}

/// The file id the request's book is loaded under. Only this service's store ever sees it.
const request_book_id = "__request__";

fn requestSeed(chat_file: []const u8, generation_type: []const u8, rotation_index: i64, history_len: usize) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(chat_file);
    h.update(generation_type);
    h.update(std.mem.asBytes(&rotation_index));
    h.update(std.mem.asBytes(&history_len));
    return h.final();
}

const Anchors = struct { before: []const u8 = "", after: []const u8 = "" };

fn noteAnchors(note: authors_note.Note) Anchors {
    if (!note.active()) return .{};
    return switch (note.position) {
        .before_prompt => .{ .before = note.prompt },
        .in_prompt => .{ .after = note.prompt },
        .in_chat => .{},
    };
}

fn charaFilename(avatar: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, avatar, '.') orelse return avatar;
    if (std.mem.indexOfScalarPos(u8, avatar, dot, '/') != null) return avatar;
    return avatar[0..dot];
}

const Persona = struct { name: []const u8 = "User", description: []const u8 = "" };

/// The persona the send speaks as, by the classic precedence the browser uses: the blob's
/// `user_avatar`, then `power_user.default_persona`, then the first persona in the map.
fn activePersona(a: Allocator, settings_str: []const u8) Allocator.Error!Persona {
    const list = char_data.extractPersonas(a, settings_str) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    if (list.len == 0) return .{};

    const root = std.json.parseFromSliceLeaky(Value, a, settings_str, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return personaAt(list, 0),
    };
    if (root != .object) return personaAt(list, 0);
    const selected = blk: {
        const ua = strOf(root.object.get("user_avatar"));
        if (ua.len > 0) break :blk ua;
        const pu = root.object.get("power_user") orelse break :blk "";
        if (pu != .object) break :blk "";
        break :blk strOf(pu.object.get("default_persona"));
    };
    if (selected.len > 0) {
        for (list, 0..) |p, i| {
            if (std.mem.eql(u8, p.avatar, selected)) return personaAt(list, i);
        }
    }
    return personaAt(list, 0);
}

fn personaAt(list: []const char_data.PersonaJson, i: usize) Persona {
    return .{ .name = list[i].name, .description = list[i].description };
}

// ---- tolerant JSON reads (the request comes off the wire; never trust a shape) -----------------

fn strOf(v: ?Value) []const u8 {
    const val = v orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

fn boolOf(v: ?Value, default: bool) bool {
    const val = v orelse return default;
    return switch (val) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => default,
    };
}

fn intOf(v: ?Value, default: i64) i64 {
    const val = v orelse return default;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @as(i64, @intFromFloat(f)) else default,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch default,
        else => default,
    };
}

/// A sub-document as TEXT: the settings blob arrives as the JSON string the settings endpoint
/// serves, but a host that already parsed it may send the object instead. Both are accepted.
fn jsonText(a: Allocator, v: ?Value) Allocator.Error![]const u8 {
    const val = v orelse return "{}";
    return switch (val) {
        .string => |s| s,
        else => try std.json.Stringify.valueAlloc(a, val, .{}),
    };
}

/// The same sub-document as a VALUE, parsing the string spelling when that is what arrived.
fn asObjectValue(a: Allocator, v: ?Value) Allocator.Error!Value {
    const val = v orelse return Value{ .object = .empty };
    return switch (val) {
        .object => val,
        .string => |s| std.json.parseFromSliceLeaky(Value, a, s, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => Value{ .object = .empty },
        },
        else => Value{ .object = .empty },
    };
}

// ---- card reads (the v2 `data` object wins, top-level is the v1 fallback) ----------------------

fn cardStr(obj: *const std.json.ObjectMap, key: []const u8) []const u8 {
    return strOf(obj.get(key));
}

fn cardDataStr(obj: *const std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get("data")) |d| {
        if (d == .object) {
            const v = strOf(d.object.get(key));
            if (v.len > 0) return v;
        }
    }
    return cardStr(obj, key);
}

const DepthPrompt = struct { prompt: []const u8, depth: i64, role: authors_note.Role };

fn cardDepthPrompt(obj: *const std.json.ObjectMap) DepthPrompt {
    var out = DepthPrompt{ .prompt = "", .depth = authors_note.default_depth, .role = .system };
    const card_data = obj.get("data") orelse return out;
    if (card_data != .object) return out;
    const ext = card_data.object.get("extensions") orelse return out;
    if (ext != .object) return out;
    const dp = ext.object.get("depth_prompt") orelse return out;
    if (dp != .object) return out;
    out.prompt = strOf(dp.object.get("prompt"));
    out.depth = intOf(dp.object.get("depth"), authors_note.default_depth);
    out.role = authors_note.Role.fromInt(intOf(dp.object.get("role"), 0)) orelse .system;
    return out;
}

fn cardAltGreetings(a: Allocator, obj: *const std.json.ObjectMap) Allocator.Error![]const []const u8 {
    const card_data = obj.get("data") orelse return &.{};
    if (card_data != .object) return &.{};
    const ag = card_data.object.get("alternate_greetings") orelse return &.{};
    if (ag != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (ag.array.items) |item| {
        if (item == .string) try out.append(a, item.string);
    }
    return out.toOwnedSlice(a);
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

const sample_request =
    \\{
    \\ "settings": {
    \\   "main_api": "textgenerationwebui",
    \\   "textgenerationwebui_settings": { "type": "llamacpp", "server_urls": { "llamacpp": "http://127.0.0.1:8080" } },
    \\   "max_context": 4096,
    \\   "amount_gen": 200,
    \\   "user_avatar": "jamie.png",
    \\   "power_user": {
    \\     "personas": { "jamie.png": "Jamie" },
    \\     "persona_descriptions": { "jamie.png": { "description": "A tired operator." } },
    \\     "context": { "story_string": "{{description}}", "chat_start": "***" }
    \\   }
    \\ },
    \\ "card": { "name": "Aria", "description": "Aria is a lighthouse keeper.", "first_mes": "The lamp is lit." },
    \\ "messages": [ { "name": "Jamie", "mes": "is the lamp still lit", "is_user": true, "is_system": false } ],
    \\ "chat_metadata": { "note_prompt": "" },
    \\ "world": { "entries": {} },
    \\ "chat": { "avatar_url": "aria.png", "file_name": "aria - 2026-08-06", "group_id": "" },
    \\ "browser": { "input": "is the lamp still lit", "utc_offset_minutes": 60, "is_mobile": false, "generation_type": "normal", "rotation_index": 0 }
    \\}
;

const PiecesOut = struct {
    pieces: []struct { kind: []const u8, text: []const u8 },
    stop: [][]const u8,
    reply_prefix: []const u8,
};

test "pieces_returns_one_costable_entry_per_prompt_part" {
    const out = try piecesJson(testing.allocator, sample_request);
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(PiecesOut, testing.allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // overhead + alignment + the single history turn.
    try testing.expectEqual(@as(usize, 3), parsed.value.pieces.len);
    try testing.expectEqualStrings("overhead", parsed.value.pieces[0].kind);
    try testing.expectEqualStrings("alignment", parsed.value.pieces[1].kind);
    try testing.expectEqualStrings("history", parsed.value.pieces[2].kind);
    try testing.expect(std.mem.indexOf(u8, parsed.value.pieces[0].text, "Aria is a lighthouse keeper.") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.pieces[2].text, "is the lamp still lit") != null);
    try testing.expect(parsed.value.stop.len > 0);
    try testing.expectEqualStrings("\nAria:", parsed.value.reply_prefix);
}

test "fit_joins_the_pieces_the_costs_leave_inside_the_budget" {
    const with_costs =
        \\{ "costs": [4, 0, 8],
    ++ sample_request[1..];

    const out = try fitJson(testing.allocator, with_costs);
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(struct { prompt: []const u8 }, testing.allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.prompt, "Aria is a lighthouse keeper.") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.prompt, "Jamie: is the lamp still lit") != null);
    try testing.expect(std.mem.endsWith(u8, parsed.value.prompt, "Aria:"));
}

test "fit_rejects_a_costs_array_that_does_not_match_the_pieces" {
    const short =
        \\{ "costs": [1],
    ++ sample_request[1..];
    const out = try fitJson(testing.allocator, short);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"error\":\"CostArityMismatch\"}", out);
}

test "malformed_input_answers_with_an_error_object" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "{not json", .want = "{\"error\":\"ParseFailed\"}" },
        .{ .in = "[1,2]", .want = "{\"error\":\"NotAnObject\"}" },
        .{ .in = "{}", .want = "{\"error\":\"UnsupportedApi\"}" },
        .{ .in = "{\"settings\":{\"main_api\":\"textgenerationwebui\"}}", .want = "{\"error\":\"MissingConnection\"}" },
    };
    for (cases) |c| {
        const out = try piecesJson(testing.allocator, c.in);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "an_error_answer_leaves_no_state_behind_for_the_next_request" {
    const bad = try piecesJson(testing.allocator, "{}");
    testing.allocator.free(bad);
    const good = try piecesJson(testing.allocator, sample_request);
    defer testing.allocator.free(good);
    try testing.expect(std.mem.indexOf(u8, good, "\"reply_prefix\"") != null);
}

fn piecesRoundTrip(a: Allocator, input: []const u8) !void {
    const out = try piecesJson(a, input);
    a.free(out);
}

test "pieces_cleans_up_on_every_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, piecesRoundTrip, .{@as([]const u8, sample_request)});
}

fn fitRoundTrip(a: Allocator, input: []const u8) !void {
    const out = try fitJson(a, input);
    a.free(out);
}

test "fit_cleans_up_on_every_allocation_failure" {
    const with_costs =
        \\{ "costs": [4, 0, 8],
    ++ sample_request[1..];
    try testing.checkAllAllocationFailures(testing.allocator, fitRoundTrip, .{@as([]const u8, with_costs)});
}
