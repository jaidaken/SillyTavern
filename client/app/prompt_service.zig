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
const macro_vars = @import("./pages/setup/macro_vars.zig");

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
    const chat = built.conn.family == .openai;

    var list = std.json.Array.init(a);
    // In openai mode the pieces carry the RAW texts (the host tokenizes exactly what the chat messages
    // will contain): the story, the alignment, each injection and turn without their template wrapper.
    // The arity is unchanged (2 + injections + history), so fitBody's cost table lines up identically.
    try list.append(try pieceValue(a, "overhead", if (chat) p.story else p.overhead));
    try list.append(try pieceValue(a, "alignment", if (chat) p.alignment_raw else p.alignment));
    for (p.injections) |inj| try list.append(try pieceValue(a, "injection", if (chat) inj.raw else inj.wrapped));
    for (p.wrapped_history, 0..) |w, i| try list.append(try pieceValue(a, "history", if (chat) p.history_raw[i] else w));

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
    const budget = generate.promptTokenBudget(built.conn);
    var root: std.json.ObjectMap = .empty;
    if (built.conn.family == .openai) {
        // The openai family answers with a chat_messages array (role + raw content) instead of the flat
        // prompt; the host forwards it verbatim as the request `messages`.
        const msgs = try generate.fitMessages(a, p, table, budget);
        var arr = std.json.Array.init(a);
        for (msgs) |m| {
            var o: std.json.ObjectMap = .empty;
            try o.put(a, "role", .{ .string = @tagName(m.role) });
            try o.put(a, "content", .{ .string = m.content });
            try arr.append(.{ .object = o });
        }
        try root.put(a, "chat_messages", .{ .array = arr });
        try root.put(a, "prompt", .{ .string = "" });
    } else {
        const prompt = try generate.fitAndAssemble(a, p, table, budget);
        try root.put(a, "prompt", .{ .string = prompt });
    }
    // Stops ride the FIT answer too: without them a model runs past the end of its own turn and
    // writes the user's next line.
    var stops = std.json.Array.init(a);
    for (built.stop) |s| try stops.append(.{ .string = s });
    try root.put(a, "stop", .{ .array = stops });
    // The BIAS, not `pieces.prefix`: the prefix is the prompt's trailing cue (it may carry the bias, or
    // not, depending on the template), while what a host needs back is the text the saved reply opens
    // with. Emitting the cue here had the route seeding replies with "\nAria:".
    try root.put(a, "bias", .{ .string = built.pieces.bias });
    // The advanced sticky/cooldown windows. `pieces` reports them too, but `fit` is the call a host
    // makes for a finished send, and without them here nothing ever writes the new state back: a
    // sticky entry would never expire and a cooldown would never count down.
    try root.put(a, "timed", try timedValue(a, built.pieces.timed_json));
    if (try dirtyStoreValue(a, built.vars.chat)) |v| try root.put(a, "variables", v);
    if (try dirtyStoreValue(a, built.vars.global)) |v| try root.put(a, "global_variables", v);
    return std.json.Stringify.valueAlloc(a, Value{ .object = root }, .{});
}

/// The whole store as `{ name: value }`, but only when a `{{setvar}}` actually wrote to it. Null keeps
/// the field out of the answer entirely, which is the host's signal that there is nothing to persist.
fn dirtyStoreValue(a: Allocator, store: ?*macro_vars.Store) Allocator.Error!?Value {
    const s = store orelse return null;
    if (!s.dirty) return null;
    var obj: std.json.ObjectMap = .empty;
    var it = s.map.iterator();
    while (it.next()) |e| try obj.put(a, e.key_ptr.*, .{ .string = e.value_ptr.* });
    return Value{ .object = obj };
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
    /// The raw history the pieces were assembled from, needed for the openai chat_messages array.
    history: []const generate.PromptMsg,
    /// The variable stores this build read and, where a `{{setvar}}` fired, wrote. The host persists
    /// them; a store that stayed clean is not reported at all, so a plain read never rewrites a file.
    vars: macro_vars.Stores,
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

    // The chat file does not necessarily carry the greeting: this client reconstructs it whenever the
    // window reaches the head and the first row is not already an assistant turn (char_api.zig:2233).
    // Without the same rule here every depth-anchored injection lands one message off, so the
    // difference is not just a missing line.
    const at_head = boolOf(doc.get("at_head"), true);
    const head_lacks_greeting = history.items.len == 0 or history.items[0].role == .user;
    if (at_head and head_lacks_greeting and first_mes.len > 0) {
        const greeting = try generate.substituteMacros(a, first_mes, .{
            .char = char_name,
            .user = persona.name,
            .persona = persona.description,
            .description = description,
            .personality = personality,
            .scenario = scenario,
            .mes_example = mes_example,
            .chat_id = chat_file,
        });
        try history.insert(a, 0, .{ .name = char_name, .mes = greeting, .role = .assistant });
        try chat_msgs.insert(a, 0, .{ .name = char_name, .mes = greeting, .is_user = false, .is_system = false });
    }

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

    // Chat variables live in the chat's own metadata, globals in the settings blob, exactly where the
    // old frontend kept them; loading both here is what lets `{{getvar}}` read across a page reload.
    const vars: macro_vars.Stores = .{
        .chat = try loadVarStore(a, objectField(meta, "variables")),
        .global = try loadVarStore(a, globalVarsValue(doc)),
    };

    var ctx = generate.Ctx{
        .chat = .{ .messages = chat_msgs.items },
        .vars = vars,
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
        .history = history.items,
        .vars = vars,
    };
}

/// A `{ name: value }` object as a variable store. Arena-owned like everything else here. Values that
/// are not strings are carried as their JSON text, which is how the old frontend stored a list.
fn loadVarStore(a: Allocator, value: ?Value) RequestError!*macro_vars.Store {
    const store = try a.create(macro_vars.Store);
    store.* = .{};
    const obj = switch (value orelse Value{ .null = {} }) {
        .object => |o| o,
        else => return store,
    };
    var it = obj.iterator();
    while (it.next()) |e| {
        const text = switch (e.value_ptr.*) {
            .string => |s| s,
            else => try std.json.Stringify.valueAlloc(a, e.value_ptr.*, .{}),
        };
        try store.set(a, e.key_ptr.*, text);
    }
    // Loading is not a write: only a {{setvar}} during the build marks the store for persistence.
    store.dirty = false;
    return store;
}

/// `settings.extension_settings.variables.global`, where the old frontend kept global variables.
fn globalVarsValue(doc: std.json.ObjectMap) ?Value {
    const settings = objectField(doc.get("settings") orelse return null, "extension_settings") orelse return null;
    const variables = objectField(settings, "variables") orelse return null;
    return objectField(variables, "global");
}

/// One field of a JSON object, or null when the value is not an object or lacks the field.
fn objectField(value: ?Value, name: []const u8) ?Value {
    return switch (value orelse return null) {
        .object => |o| o.get(name),
        else => null,
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
    // A card writes this role as a NAME ("assistant"), not an ordinal. Reading it as an integer only
    // silently made every card note a system note, which puts it in a different bucket at the same
    // depth and reorders the injection against world info (char_api.zig:1339 does both).
    if (dp.object.get("role")) |v| out.role = switch (v) {
        .integer => |i| authors_note.Role.fromInt(i) orelse .system,
        .float => |f| authors_note.Role.fromInt(@intFromFloat(f)) orelse .system,
        .string => |name| roleFromName(name),
        else => .system,
    };
    return out;
}

fn roleFromName(s: []const u8) authors_note.Role {
    if (std.ascii.eqlIgnoreCase(s, "user")) return .user;
    if (std.ascii.eqlIgnoreCase(s, "assistant")) return .assistant;
    return .system;
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

    // overhead + alignment + the reconstructed greeting + the single history turn. The card carries a
    // first_mes and the window is at the head, so the greeting is a history turn like the client's.
    try testing.expectEqual(@as(usize, 4), parsed.value.pieces.len);
    try testing.expectEqualStrings("overhead", parsed.value.pieces[0].kind);
    try testing.expectEqualStrings("alignment", parsed.value.pieces[1].kind);
    try testing.expectEqualStrings("history", parsed.value.pieces[2].kind);
    try testing.expectEqualStrings("history", parsed.value.pieces[3].kind);
    try testing.expect(std.mem.indexOf(u8, parsed.value.pieces[0].text, "Aria is a lighthouse keeper.") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.pieces[3].text, "is the lamp still lit") != null);
    try testing.expect(parsed.value.stop.len > 0);
    try testing.expectEqualStrings("\nAria:", parsed.value.reply_prefix);
}

test "fit_joins_the_pieces_the_costs_leave_inside_the_budget" {
    const with_costs =
        \\{ "costs": [4, 0, 2, 8],
    ++ sample_request[1..];

    const out = try fitJson(testing.allocator, with_costs);
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(struct { prompt: []const u8 }, testing.allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.prompt, "Aria is a lighthouse keeper.") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.prompt, "Jamie: is the lamp still lit") != null);
    try testing.expect(std.mem.endsWith(u8, parsed.value.prompt, "Aria:"));
}

/// The same scenario with a chat variable set, and a card that reads and writes variables. The
/// description is where the macros sit because a card field is substituted on every build.
const vars_request =
    \\{
    \\ "settings": { "main_api": "textgenerationwebui", "textgenerationwebui_settings": { "type": "ooba", "max_length": 4096, "genamt": 256 },
    \\               "extension_settings": { "variables": { "global": { "era": "third" } } } },
    \\ "card": { "name": "Aria", "description": "Aria keeps lamp {{getvar::lamp}} in the {{getglobalvar::era}} age.{{setvar::seen::yes}}", "first_mes": "The lamp is lit." },
    \\ "messages": [ { "name": "Jamie", "mes": "is the lamp still lit", "is_user": true, "is_system": false } ],
    \\ "chat_metadata": { "note_prompt": "", "variables": { "lamp": "seven" } },
    \\ "world": { "entries": {} },
    \\ "chat": { "avatar_url": "aria.png", "file_name": "aria - 2026-08-06", "group_id": "" },
    \\ "browser": { "input": "is the lamp still lit", "utc_offset_minutes": 60, "is_mobile": false, "generation_type": "normal", "rotation_index": 0 }
    \\}
;

test "a_build_reads_chat_and_global_variables_into_the_prompt" {
    const out = try piecesJson(testing.allocator, vars_request);
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(PiecesOut, testing.allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testing.expect(std.mem.indexOf(u8, parsed.value.pieces[0].text, "Aria keeps lamp seven in the third age.") != null);
}

test "a_setvar_during_the_build_is_reported_back_for_the_host_to_persist" {
    const with_costs =
        \\{ "costs": [4, 0, 2, 8],
    ++ vars_request[1..];

    const out = try fitJson(testing.allocator, with_costs);
    defer testing.allocator.free(out);

    const Out = struct {
        prompt: []const u8,
        variables: ?struct { lamp: []const u8, seen: []const u8 } = null,
        global_variables: ?struct { era: []const u8 } = null,
    };
    const parsed = try std.json.parseFromSlice(Out, testing.allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // The chat store was written, so it comes back whole; the global store was only read, so it is
    // absent and the host has nothing to rewrite.
    try testing.expectEqualStrings("yes", parsed.value.variables.?.seen);
    try testing.expectEqualStrings("seven", parsed.value.variables.?.lamp);
    try testing.expect(parsed.value.global_variables == null);
}

test "fit_answers_with_the_bias_resolved_against_the_variable_store" {
    const with_costs =
        \\{ "costs": [4, 0, 2, 8],
    ++ bias_request[1..];

    const out = try fitJson(testing.allocator, with_costs);
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(struct { prompt: []const u8, bias: []const u8 }, testing.allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // The bias is what the saved reply opens with, so it comes back resolved, not as a template.
    try testing.expectEqualStrings(" [mood: wary]", parsed.value.bias);
    try testing.expect(std.mem.endsWith(u8, parsed.value.prompt, " [mood: wary]"));
}

/// A configured prompt bias that reads a chat variable, the case the client could never expand.
const bias_request =
    \\{
    \\ "settings": { "main_api": "textgenerationwebui", "textgenerationwebui_settings": { "type": "ooba", "max_length": 4096, "genamt": 256 },
    \\               "power_user": { "user_prompt_bias": " [mood: {{getvar::mood}}]" } },
    \\ "card": { "name": "Aria", "description": "Aria is a lighthouse keeper.", "first_mes": "The lamp is lit." },
    \\ "messages": [ { "name": "Jamie", "mes": "is the lamp still lit", "is_user": true, "is_system": false } ],
    \\ "chat_metadata": { "note_prompt": "", "variables": { "mood": "wary" } },
    \\ "world": { "entries": {} },
    \\ "chat": { "avatar_url": "aria.png", "file_name": "aria - 2026-08-06", "group_id": "" },
    \\ "browser": { "input": "is the lamp still lit", "utc_offset_minutes": 60, "is_mobile": false, "generation_type": "normal", "rotation_index": 0 }
    \\}
;

test "fit_answers_with_the_stop_set_and_the_reply_prefix_not_only_the_prompt" {
    const with_costs =
        \\{ "costs": [4, 0, 2, 8],
    ++ chatml_request[1..];

    const out = try fitJson(testing.allocator, with_costs);
    defer testing.allocator.free(out);

    const Out = struct { prompt: []const u8, stop: [][]const u8 };
    const parsed = try std.json.parseFromSlice(Out, testing.allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // fit is the call a host makes to get a finished send; a prompt alone is not one.
    var has_end = false;
    for (parsed.value.stop) |s| {
        if (std.mem.indexOf(u8, s, "<|im_end|>") != null) has_end = true;
    }
    try testing.expect(has_end);
    try testing.expect(parsed.value.prompt.len > 0);
}

/// The same scenario under an instruct template, so the stop set is not empty by construction.
const chatml_request =
    \\{
    \\ "settings": { "main_api": "textgenerationwebui", "textgenerationwebui_settings": { "type": "ooba", "max_length": 4096, "genamt": 256 },
    \\               "power_user": { "instruct": { "enabled": "true", "name": "ChatML", "input_sequence": "<|im_start|>user",
    \\                 "output_sequence": "<|im_start|>assistant", "system_sequence": "<|im_start|>system", "stop_sequence": "<|im_end|>",
    \\                 "input_suffix": "<|im_end|>\n", "output_suffix": "<|im_end|>\n", "system_suffix": "<|im_end|>\n", "wrap": true, "macro": true } } },
    \\ "card": { "name": "Aria", "description": "Aria is a lighthouse keeper.", "first_mes": "The lamp is lit." },
    \\ "messages": [ { "name": "Jamie", "mes": "is the lamp still lit", "is_user": true, "is_system": false } ],
    \\ "chat_metadata": { "note_prompt": "" },
    \\ "world": { "entries": {} },
    \\ "chat": { "avatar_url": "aria.png", "file_name": "aria - 2026-08-06", "group_id": "" },
    \\ "browser": { "input": "is the lamp still lit", "utc_offset_minutes": 60, "is_mobile": false, "generation_type": "normal", "rotation_index": 0 }
    \\}
;

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
        \\{ "costs": [4, 0, 2, 8],
    ++ sample_request[1..];
    try testing.checkAllAllocationFailures(testing.allocator, fitRoundTrip, .{@as([]const u8, with_costs)});
}
