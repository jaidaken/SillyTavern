//! World-info activation engine (3b-B): which entries fire for a send, and the text each prompt
//! slot receives. Pure and zx-free, proven under `zig build test`; generate.zig runs it inside
//! `buildPromptBudgeted` and char_api supplies the store-owned candidate entries.
//!
//! Semantics follow the classic client (public/scripts/world-info.js, checked 2026-07-17):
//! candidate PRIORITY (probability + budget) is the caller's list order (chat lore, then character,
//! then global; each book by `order` descending, sortFn :89 + the character_first default strategy);
//! the JOINED text follows stock's descending-sort-then-distribute (:5082): unshift for every bucket
//! but outlets (order-ascending, ties reversed), push for outlets (order-descending, ties kept).
//! Matching is case-insensitive ASCII substring over the newest `scan_depth`
//! message texts (probe#3: "ASCII substring"); recursion re-scans activated content when enabled
//! (stock world_info_recursive, default off). The budget cap bounds the WI slice ONLY (probe#3
//! delta 2): an entry that would reach the cap is dropped and activation stops, so the
//! lowest-priority entries are what a tight budget sheds.

const std = @import("std");

const wi = @import("./world_info.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.wi);

pub const Entry = wi.Entry;

/// One persisted timed effect (stock WITimedEffect). `hash` identifies the entry the effect
/// belongs to (an entry whose content changed no longer matches and the effect expires); `start`
/// / `end` bound it in message counts; `protected` keeps it alive on the message it was created.
pub const Effect = struct { hash: u64, start: i64, end: i64, protected: bool };

/// One keyed effect. `key` = "<world>.<uid>" (stock #getEntryKey), the slot the effect persists in.
pub const Timed = struct { key: []const u8, effect: Effect };

/// The chat-persisted timed-effect state (stock chat_metadata.timedWorldInfo). `sticky` + `cooldown`
/// round-trip through chat metadata; `delay` is not persisted (recomputed live from entry.delay).
/// `timed_in` is caller-owned and read-only; `timed_out` lives in the Activation arena.
pub const TimedState = struct { sticky: []const Timed = &.{}, cooldown: []const Timed = &.{} };

/// Stock #getEntryHash surrogate: a stable per-entry hash over the fields that identify the entry
/// and its content. Internal-consistency only (not stock's getStringHash(JSON.stringify) bytes): the
/// same entry hashes the same across sends, an edited entry hashes differently so its effect expires.
fn entryHash(e: Entry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(e.world);
    h.update(std.mem.asBytes(&e.uid));
    h.update(e.content);
    return h.final();
}

fn findByHash(entries: []const Entry, hash: u64) ?usize {
    for (entries, 0..) |e, i| {
        if (entryHash(e) == hash) return i;
    }
    return null;
}

fn timedIndexOf(list: []const Timed, key: []const u8) ?usize {
    for (list, 0..) |t, i| {
        if (std.mem.eql(u8, t.key, key)) return i;
    }
    return null;
}

/// Insert or replace the effect at `key`, duping the key into the arena on insert (stock's
/// object-assign semantics: a re-set overwrites the slot).
fn putTimed(a: Allocator, list: *std.ArrayList(Timed), key: []const u8, effect: Effect) Allocator.Error!void {
    if (timedIndexOf(list.items, key)) |i| {
        list.items[i].effect = effect;
        return;
    }
    try list.append(a, .{ .key = try a.dupe(u8, key), .effect = effect });
}

fn entryKey(a: Allocator, e: Entry) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}.{d}", .{ e.world, e.uid });
}

/// Stock #checkTimedEffectOfType (world-info.js:620): validates one stored effect against the
/// current chat length, marks the entry active in `active` and carries the effect into `out_list`
/// when it still holds, else drops it. A sticky effect that just ended starts the entry's cooldown
/// (onEnded :519), which lands in `out_cool` protected and marks the entry cooldown-active this scan.
fn checkTimedEffect(
    a: Allocator,
    comptime kind: enum { sticky, cooldown },
    entries: []const Entry,
    t: Timed,
    chat_len: i64,
    active: []bool,
    out_list: *std.ArrayList(Timed),
    out_cool: *std.ArrayList(Timed),
    cooldown_active: []bool,
) Allocator.Error!void {
    // Chat has not advanced past the effect's start and it is not protected: drop (:627).
    if (chat_len <= t.effect.start and !t.effect.protected) return;

    const entry_idx = findByHash(entries, t.effect.hash);
    if (entry_idx == null) {
        // Entry gone (e.g. another character's book): keep until its interval passes (:634).
        if (chat_len >= t.effect.end) return;
        try putTimed(a, out_list, t.key, t.effect);
        return;
    }
    const i = entry_idx.?;
    const cfg: i64 = if (kind == .sticky) entries[i].sticky else entries[i].cooldown;
    // Entry no longer configured for this effect: drop (:643).
    if (cfg == 0) return;

    if (chat_len >= t.effect.end) {
        // Interval passed: drop. A sticky end immediately opens the entry's cooldown (:519).
        if (kind == .sticky) {
            const cd = entries[i].cooldown;
            if (cd != 0) {
                const key = try entryKey(a, entries[i]);
                try putTimed(a, out_cool, key, .{ .hash = entryHash(entries[i]), .start = chat_len, .end = chat_len + cd, .protected = true });
                cooldown_active[i] = true;
            }
        }
        return;
    }

    active[i] = true;
    try putTimed(a, out_list, t.key, t.effect);
}

fn stickyFirst(sticky: []const bool, l: usize, r: usize) bool {
    return sticky[l] and !sticky[r];
}

// ---- persistence (chat_metadata.timedWorldInfo <-> TimedState) ----------------------------------

/// Serialize a TimedState to the stock chat_metadata.timedWorldInfo JSON shape:
/// `{ "sticky": { "<world>.<uid>": {hash,start,end,protected}, ... }, "cooldown": {...} }`. Built in
/// `a` (the caller's chat-metadata arena); the result stringifies straight, no engine internals.
pub fn writeTimedState(a: Allocator, ts: TimedState) Allocator.Error!std.json.Value {
    var root: std.json.ObjectMap = .empty;
    try root.put(a, "sticky", try timedToObject(a, ts.sticky));
    try root.put(a, "cooldown", try timedToObject(a, ts.cooldown));
    return .{ .object = root };
}

fn timedToObject(a: Allocator, list: []const Timed) Allocator.Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (list) |t| {
        var row: std.json.ObjectMap = .empty;
        // hash is u64; number_string keeps full precision past json's i64 integer.
        try row.put(a, "hash", .{ .number_string = try std.fmt.allocPrint(a, "{d}", .{t.effect.hash}) });
        try row.put(a, "start", .{ .integer = t.effect.start });
        try row.put(a, "end", .{ .integer = t.effect.end });
        try row.put(a, "protected", .{ .bool = t.effect.protected });
        try obj.put(a, t.key, .{ .object = row });
    }
    return .{ .object = obj };
}

/// Parse a TimedState from the stock chat_metadata.timedWorldInfo shape. Tolerant: a non-object or a
/// malformed row is skipped. Slices are allocated in `a` (pass the same arena you feed to activate).
pub fn readTimedState(a: Allocator, v: std.json.Value) Allocator.Error!TimedState {
    if (v != .object) return .{};
    return .{
        .sticky = try objectToTimed(a, v.object.get("sticky")),
        .cooldown = try objectToTimed(a, v.object.get("cooldown")),
    };
}

fn objectToTimed(a: Allocator, v: ?std.json.Value) Allocator.Error![]const Timed {
    const val = v orelse return &.{};
    if (val != .object) return &.{};
    var out: std.ArrayList(Timed) = .empty;
    errdefer out.deinit(a);
    var it = val.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        const row = &kv.value_ptr.object;
        const key = try a.dupe(u8, kv.key_ptr.*);
        try out.append(a, .{ .key = key, .effect = .{
            .hash = jHash(row),
            .start = jInt(row, "start"),
            .end = jInt(row, "end"),
            .protected = jBool(row, "protected"),
        } });
    }
    return out.toOwnedSlice(a);
}

fn jHash(obj: *const std.json.ObjectMap) u64 {
    const v = obj.get("hash") orelse return 0;
    return switch (v) {
        .integer => |i| @bitCast(i),
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn jInt(obj: *const std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else 0,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

fn jBool(obj: *const std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => false,
    };
}

/// Tolerant read of the timed state from a chat header's metadata JSON (stock chat_metadata),
/// unwrapping its `timedWorldInfo` field. Absent/empty/malformed yields the empty state (a chat
/// with no timed history just starts fresh). Slices live in `a`.
pub fn readTimedFromMetadata(a: Allocator, chat_metadata: []const u8) TimedState {
    if (chat_metadata.len == 0) return .{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, chat_metadata, .{}) catch return .{};
    if (root != .object) return .{};
    const v = root.object.get("timedWorldInfo") orelse return .{};
    return readTimedState(a, v) catch .{};
}

/// Tolerant read of a bare timed-state value string (the shape writeTimedState emits): what a send
/// persists then reloads to advance its held state. Empty/malformed yields empty. Slices live in `a`.
pub fn readTimedFromJson(a: Allocator, json: []const u8) TimedState {
    if (json.len == 0) return .{};
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return .{};
    return readTimedState(a, v) catch .{};
}

/// Activation inputs. `entries` must already be in priority order (WorldInfoStore.collectActive).
/// A null `rng` skips the probability roll entirely (every roll passes); the send path always
/// supplies one, tests pass a seeded PRNG.
pub const Params = struct {
    entries: []const Entry = &.{},
    scan_depth: usize = 2,
    budget_chars: usize = std.math.maxInt(usize),
    recursive: bool = false,
    rng: ?std.Random = null,
    /// Stock world_info_case_sensitive: the default a null per-entry caseSensitive falls back to.
    case_sensitive: bool = false,
    /// Stock world_info_match_whole_words: default for a null per-entry matchWholeWords.
    match_whole_words: bool = false,
    /// Stock world_info_min_activations: keep widening the scan window until this many entries fire.
    min_activations: usize = 0,
    /// Stock world_info_min_activations_depth_max: hard cap on the widened depth. 0 = bounded only
    /// by the history length.
    min_activations_depth_max: usize = 0,
    /// Stock world_info_use_group_scoring: the default a null per-entry useGroupScoring falls back to.
    use_group_scoring: bool = false,
    /// The chat's persisted timed-effect state (stock chat_metadata.timedWorldInfo) at scan start.
    /// Caller-owned, read-only; the updated state comes back as Activation.timed_out.
    timed_in: TimedState = .{},
    /// Stock getCharaFilename(): the selected character's avatar-derived filename, matched against an
    /// entry's characterFilter.names. Empty when no character is selected.
    chara_filename: []const u8 = "",
    /// Stock context.tagMap[tagKey]: the selected character's assigned tag IDs, matched against an
    /// entry's characterFilter.tags. NULL when the character has no tag mapping at all, so the tag
    /// filter is skipped outright (stock's `if (tagKey) { if (Array.isArray(tagMapEntry)) }` guard); a
    /// non-null empty slice means the character has an EMPTY tag list, which an include filter rejects.
    char_tags: ?[]const []const u8 = null,
    /// Stock globalScanData.trigger: the current generation type (normal, continue, impersonate,
    /// swipe, regenerate, quiet). An entry with a non-empty triggers list fires only when it lists this.
    generation_trigger: []const u8 = "normal",
    /// Stock globalScanData scan sources: extra text an entry may also scan for its keys, each gated by
    /// its per-entry match flag AND being non-empty. They join the entry's own chat window, so they are
    /// scanned even during a min-activations sweep but never when the entry's resolved depth is <= 0.
    persona_description: []const u8 = "",
    character_description: []const u8 = "",
    character_personality: []const u8 = "",
    character_depth_prompt: []const u8 = "",
    scenario: []const u8 = "",
    creator_notes: []const u8 = "",
};

/// One merged at-depth injection: every activated atDepth entry at this depth AND role, joined.
/// role: 0 system, 1 user, 2 assistant (stock groups by depth+role, world-info.js:5115).
pub const DepthGroup = struct { depth: i64, role: i64 = 0, content: []const u8 };

/// One named outlet: every activated outlet entry with this outletName, joined. Feeds the
/// {{outlet::name}} macro (stock world-info.js:5127); a nameless outlet entry is skipped as stock.
pub const OutletGroup = struct { name: []const u8, content: []const u8 };

/// The activated text per prompt slot. All slices live in the arena; free with `deinit`.
pub const Activation = struct {
    arena: std.heap.ArenaAllocator,
    before: []const u8 = "",
    after: []const u8 = "",
    an_top: []const u8 = "",
    an_bottom: []const u8 = "",
    em_top: []const []const u8 = &.{},
    em_bottom: []const []const u8 = &.{},
    at_depth: []const DepthGroup = &.{},
    outlets: []const OutletGroup = &.{},
    /// The updated timed-effect state to persist back to chat metadata. Lives in `arena`, so
    /// serialize it into chat metadata BEFORE calling deinit.
    timed_out: TimedState = .{},

    pub fn deinit(self: *Activation) void {
        self.arena.deinit();
    }
};

/// Runs stock checkWorldInfo's scan-state machine over `history` (message texts, OLDEST first; the
/// engine scans the newest `scan_depth` of them) and buckets the survivors by position. The state
/// walks INITIAL -> (RECURSION | MIN_ACTIVATIONS) -> NONE (world-info.js:4652). Owned result.
pub fn activate(gpa: Allocator, params: Params, history: []const []const u8) Allocator.Error!Activation {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const State = enum(u8) { idle, active, failed };
    const flags = try a.alloc(State, params.entries.len);
    @memset(flags, .idle);

    // Strip @@decorators up front (stock getSortedEntries :4515) so every downstream use, incl. the
    // timed-effect hash below, sees stripped content; entryHash over decorated content would drift.
    const entries = try a.alloc(Entry, params.entries.len);
    const dec_activate = try a.alloc(bool, params.entries.len);
    const dec_dont = try a.alloc(bool, params.entries.len);
    for (params.entries, 0..) |e, i| {
        const d = parseDecorators(e.content);
        entries[i] = e;
        entries[i].content = d.content;
        dec_activate[i] = d.activate;
        dec_dont[i] = d.dont_activate;
    }

    // Timed effects (stock WorldInfoTimedEffects). Cooldown is processed before sticky so a sticky
    // end's fresh cooldown (onEnded) is the final write for its slot, matching stock's reread order.
    const chat_len: i64 = @intCast(history.len);
    const sticky_active = try a.alloc(bool, entries.len);
    @memset(sticky_active, false);
    const cooldown_active = try a.alloc(bool, entries.len);
    @memset(cooldown_active, false);
    const delay_active = try a.alloc(bool, entries.len);
    @memset(delay_active, false);
    var out_sticky: std.ArrayList(Timed) = .empty;
    var out_cool: std.ArrayList(Timed) = .empty;
    for (params.timed_in.cooldown) |t| {
        try checkTimedEffect(a, .cooldown, entries, t, chat_len, cooldown_active, &out_cool, &out_cool, cooldown_active);
    }
    for (params.timed_in.sticky) |t| {
        try checkTimedEffect(a, .sticky, entries, t, chat_len, sticky_active, &out_sticky, &out_cool, cooldown_active);
    }
    for (entries, 0..) |e, i| {
        if (e.delay != 0 and chat_len < e.delay) delay_active[i] = true;
    }

    // Distinct positive delayUntilRecursion levels, ascending. The lowest is pre-loaded as the
    // current level; the rest open one per delayed-recursion pass (stock :4640-4645, :5008-5011).
    var delay_levels: std.ArrayList(i64) = .empty;
    for (entries) |e| {
        if (e.delay_until_recursion == 0) continue;
        var seen = false;
        for (delay_levels.items) |v| {
            if (v == e.delay_until_recursion) {
                seen = true;
                break;
            }
        }
        if (!seen) try delay_levels.append(a, e.delay_until_recursion);
    }
    std.mem.sort(i64, delay_levels.items, {}, ascI64);
    var delay_idx: usize = 0;
    var current_delay_level: i64 = 0;
    if (delay_levels.items.len > 0) {
        current_delay_level = delay_levels.items[0];
        delay_idx = 1;
    }

    var recurse: std.ArrayList([]const u8) = .empty;
    // Activation order = stock's allActivatedEntries Map insertion order (pass by pass, candidate
    // order within a pass). sortFn is stable, so equal-order ties keep THIS order, not candidate order.
    var activated: std.ArrayList(usize) = .empty;
    var used_chars: usize = 0;
    var overflow = false;
    var skew: usize = 0;

    const ScanState = enum { none, initial, recursion, min_activations };
    var scan_state: ScanState = if (params.entries.len > 0) .initial else .none;

    while (scan_state != .none) {
        // getDepth() = world_info_depth + skew (:403); the skew widens the global window during a
        // min-activations sweep. The recurse buffer is excluded during that sweep (:324).
        const global_depth: i64 = @as(i64, @intCast(params.scan_depth)) + @as(i64, @intCast(skew));
        const rec_view: []const []const u8 = if (scan_state == .min_activations) &.{} else recurse.items;

        var newly: std.ArrayList(usize) = .empty;
        for (entries, 0..) |e, i| {
            if (flags[i] != .idle) continue;
            if (e.disable) continue;
            // Generation-type trigger gate (stock :4693): a triggers list fires only for a listed type.
            if (e.triggers.len > 0 and !listContains(e.triggers, params.generation_trigger)) continue;
            // characterFilter by name then by tag (stock :4702, :4712). A null char_tags means the
            // character has no tag mapping, so stock's Array.isArray guard skips the tag filter.
            if (e.char_filter_names.len > 0) {
                const included = listContains(e.char_filter_names, params.chara_filename);
                const filtered = if (e.char_filter_exclude) included else !included;
                if (filtered) continue;
            }
            if (e.char_filter_tags.len > 0) {
                if (params.char_tags) |ctags| {
                    const includes_tag = listsIntersect(ctags, e.char_filter_tags);
                    const filtered = if (e.char_filter_exclude) includes_tag else !includes_tag;
                    if (filtered) continue;
                }
            }
            const is_sticky = sticky_active[i];
            // delay suppresses outright; cooldown suppresses unless the entry is sticky (stock :4735).
            if (delay_active[i]) continue;
            if (cooldown_active[i] and !is_sticky) continue;
            // delayUntilRecursion: suppressed outside recursion, and on recursion until its level is
            // open; a sticky entry bypasses both (stock :4746, :4751).
            if (e.delay_until_recursion != 0 and scan_state != .recursion and !is_sticky) continue;
            if (e.delay_until_recursion != 0 and scan_state == .recursion and e.delay_until_recursion > current_delay_level and !is_sticky) continue;
            // excludeRecursion: an excluded entry never fires from a recursion pass; sticky bypasses (:4756).
            if (scan_state == .recursion and params.recursive and e.exclude_recursion and !is_sticky) continue;
            // Decorators (stock :4761): @@activate forces the entry in (still runs budget + probability);
            // @@dont_activate suppresses even a constant or sticky entry. Applied before both.
            if (dec_activate[i]) {
                try newly.append(a, i);
                continue;
            }
            if (dec_dont[i]) continue;
            if (e.constant) {
                try newly.append(a, i);
                continue;
            }
            // A sticky-active entry re-activates without a key match (stock :4785).
            if (is_sticky) {
                try newly.append(a, i);
                continue;
            }
            if (e.keys.len == 0) continue;
            const cs = e.case_sensitive orelse params.case_sensitive;
            const ww = e.match_whole_words orelse params.match_whole_words;
            // Per-entry scanDepth (stock buffer.get :281) plus any gated extended sources (persona /
            // character / scenario / creator-notes text) form the entry's scan window.
            const e_scan = try entryScanFull(a, e, history, global_depth, params);
            if (!matchAnyKey(e.keys, e_scan, rec_view, cs, ww)) continue;
            if (e.selective and e.keysecondary.len > 0 and !selectiveOk(e, e_scan, rec_view, cs, ww)) continue;
            try newly.append(a, i);
        }

        // Sticky entries take budget/probability priority within the pass (stock :4880). Stable sort
        // keeps candidate order for the rest.
        std.mem.sort(usize, newly.items, @as([]const bool, sticky_active), stickyFirst);

        // Inclusion groups: prune the pass candidates to one winner per group before the budget loop
        // (stock filterByInclusionGroups :4891). activated holds prior passes, not this one yet.
        try filterByInclusionGroups(a, params, &newly, activated.items, history, global_depth, rec_view, sticky_active, cooldown_active, delay_active);

        // Budget + probability over the candidates in priority order. An ignoreBudget entry activates
        // past the cap; once overflowed, only later ignoreBudget entries are still reached (:4896-4905).
        var ignores_budget: usize = 0;
        for (newly.items) |i| {
            if (entries[i].ignore_budget) ignores_budget += 1;
        }
        for (newly.items) |i| {
            const e = entries[i];
            if (e.ignore_budget) ignores_budget -= 1;
            if (overflow and !e.ignore_budget) {
                if (ignores_budget > 0) continue else break;
            }
            // A sticky-active entry does not re-roll probability (stock :4914).
            if (e.use_probability and e.probability < 100 and !sticky_active[i]) {
                const roll: f64 = if (params.rng) |rng| rng.float(f64) * 100.0 else 0.0;
                if (roll > @as(f64, @floatFromInt(e.probability))) {
                    flags[i] = .failed;
                    continue;
                }
            }
            // Stock reaching the budget exactly also overflows (world-info.js:4940, `>=`).
            if (!e.ignore_budget and used_chars +| e.content.len +| 1 >= params.budget_chars) {
                overflow = true;
                log.debug("wi budget {d} reached, activation stopped", .{params.budget_chars});
                continue;
            }
            used_chars += e.content.len + 1;
            flags[i] = .active;
            try activated.append(a, i);
        }

        // successfulNewEntriesForRecursion (:4958-4959): passed probability (activated, budget-
        // overflowed, or unreached) and not preventRecursion. This set feeds recursion + its buffer.
        var sfr: std.ArrayList(usize) = .empty;
        for (newly.items) |i| {
            if (flags[i] == .failed) continue;
            if (entries[i].prevent_recursion) continue;
            try sfr.append(a, i);
        }

        var next_state: ScanState = .none;
        if (params.recursive and !overflow and sfr.items.len > 0) next_state = .recursion;
        // A min-activations sweep is always chased by a recursion pass to read its new buffer (:4983).
        if (params.recursive and !overflow and scan_state == .min_activations and recurse.items.len > 0) next_state = .recursion;

        const min_not_satisfied = params.min_activations > 0 and activated.items.len < params.min_activations;
        if (next_state == .none and !overflow and min_not_satisfied) {
            // over_max on the CURRENT depth, before advanceScan (:4993-4996).
            const over_max = (params.min_activations_depth_max > 0 and global_depth > @as(i64, @intCast(params.min_activations_depth_max))) or
                (global_depth > @as(i64, @intCast(history.len)));
            if (!over_max) {
                next_state = .min_activations;
                skew += 1;
            }
        }

        // Scan would stop but delayed-recursion levels remain: open the next one (:5008-5011). This
        // path is NOT gated on world_info_recursive, matching stock.
        if (next_state == .none and delay_idx < delay_levels.items.len) {
            next_state = .recursion;
            current_delay_level = delay_levels.items[delay_idx];
            delay_idx += 1;
        }

        scan_state = next_state;
        if (scan_state != .none and sfr.items.len > 0) {
            const parts = try a.alloc([]const u8, sfr.items.len);
            for (sfr.items, 0..) |i, j| parts[j] = entries[i].content;
            const text = try std.mem.join(a, "\n", parts);
            if (text.len > 0) try recurse.append(a, text);
        }
    }

    // setTimedEffects (:5153): every activated entry with a sticky/cooldown seeds its effect when the
    // slot is empty; a carried or onEnded effect already present is not overwritten.
    for (activated.items) |i| {
        const e = entries[i];
        if (e.sticky != 0) {
            const key = try entryKey(a, e);
            if (timedIndexOf(out_sticky.items, key) == null)
                try out_sticky.append(a, .{ .key = key, .effect = .{ .hash = entryHash(e), .start = chat_len, .end = chat_len + e.sticky, .protected = false } });
        }
        if (e.cooldown != 0) {
            const key = try entryKey(a, e);
            if (timedIndexOf(out_cool.items, key) == null)
                try out_cool.append(a, .{ .key = key, .effect = .{ .hash = entryHash(e), .start = chat_len, .end = chat_len + e.cooldown, .protected = false } });
        }
    }

    // Stock sorts activated entries order-DESCENDING (stable sortFn :89) then distributes with
    // unshift (all buckets + atDepth content) or push (outlets), :5082; mirror both to land ties right.
    const idx = activated;
    std.mem.sort(usize, idx.items, @as([]const Entry, entries), orderDesc);

    var before: std.ArrayList([]const u8) = .empty;
    var after: std.ArrayList([]const u8) = .empty;
    var an_top: std.ArrayList([]const u8) = .empty;
    var an_bottom: std.ArrayList([]const u8) = .empty;
    var em_top: std.ArrayList([]const u8) = .empty;
    var em_bottom: std.ArrayList([]const u8) = .empty;
    var outlets: std.ArrayList(struct { name: []const u8, buf: std.ArrayList([]const u8) }) = .empty;
    var groups: std.ArrayList(struct { depth: i64, role: i64, buf: std.ArrayList([]const u8) }) = .empty;

    for (idx.items) |i| {
        const e = entries[i];
        if (e.content.len == 0) continue;
        switch (e.position) {
            .before => try before.insert(a, 0, e.content),
            .after => try after.insert(a, 0, e.content),
            .an_top => try an_top.insert(a, 0, e.content),
            .an_bottom => try an_bottom.insert(a, 0, e.content),
            .em_top => try em_top.insert(a, 0, e.content),
            .em_bottom => try em_bottom.insert(a, 0, e.content),
            .at_depth => {
                const depth = @max(0, e.depth);
                const g = for (groups.items) |*g| {
                    if (g.depth == depth and g.role == e.role) break g;
                } else blk: {
                    try groups.append(a, .{ .depth = depth, .role = e.role, .buf = .empty });
                    break :blk &groups.items[groups.items.len - 1];
                };
                try g.buf.insert(a, 0, e.content); // unshift, :5117
            },
            .outlet => {
                if (e.outlet_name.len == 0) {
                    // Stock skips a nameless outlet entry with a warn (world-info.js:5128).
                    log.warn("wi entry {d} has the outlet position but no outlet name, skipped", .{e.uid});
                    continue;
                }
                const g = for (outlets.items) |*g| {
                    if (std.mem.eql(u8, g.name, e.outlet_name)) break g;
                } else blk: {
                    try outlets.append(a, .{ .name = e.outlet_name, .buf = .empty });
                    break :blk &outlets.items[outlets.items.len - 1];
                };
                try g.buf.append(a, e.content); // push, :5133
            },
        }
    }

    const out_groups = try a.alloc(DepthGroup, groups.items.len);
    for (groups.items, 0..) |g, i| out_groups[i] = .{ .depth = g.depth, .role = g.role, .content = try std.mem.join(a, "\n", g.buf.items) };
    const out_outlets = try a.alloc(OutletGroup, outlets.items.len);
    for (outlets.items, 0..) |g, i| out_outlets[i] = .{ .name = g.name, .content = try std.mem.join(a, "\n", g.buf.items) };

    // Every arena allocation must finish BEFORE the struct literal copies `arena` by value: a copy
    // taken first would miss any chunk a later field alloc adds, orphaning it from deinit.
    const before_s = try std.mem.join(a, "\n", before.items);
    const after_s = try std.mem.join(a, "\n", after.items);
    const an_top_s = try std.mem.join(a, "\n", an_top.items);
    const an_bottom_s = try std.mem.join(a, "\n", an_bottom.items);
    const timed_out: TimedState = .{ .sticky = try out_sticky.toOwnedSlice(a), .cooldown = try out_cool.toOwnedSlice(a) };
    return .{
        .arena = arena,
        .before = before_s,
        .after = after_s,
        .an_top = an_top_s,
        .an_bottom = an_bottom_s,
        .em_top = em_top.items,
        .em_bottom = em_bottom.items,
        .at_depth = out_groups,
        .outlets = out_outlets,
        .timed_out = timed_out,
    };
}

// Order-only so std.mem.sort (stable) keeps equal-order entries in activation order, as stock's
// stable sortFn keeps its Map insertion order.
fn orderDesc(entries: []const Entry, lhs: usize, rhs: usize) bool {
    return entries[lhs].order > entries[rhs].order;
}

fn ascI64(_: void, l: i64, r: i64) bool {
    return l < r;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn hasWhitespace(s: []const u8) bool {
    for (s) |c| if (std.ascii.isWhitespace(c)) return true;
    return false;
}

/// Case-folded substring search from `start`; a case-sensitive match is an exact byte search.
fn foldIndex(hay: []const u8, needle: []const u8, cs: bool, start: usize) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    if (cs) return std.mem.indexOfPos(u8, hay, start, needle);
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Stock matchKeys (world-info.js:338): caseSensitive lowercases both sides, matchWholeWords bounds
/// a single-word key with (?:^|\W)(key)(?:$|\W); a multi-word key falls back to plain containment.
fn textMatches(hay: []const u8, needle: []const u8, cs: bool, ww: bool) bool {
    if (needle.len == 0) return false;
    if (ww and !hasWhitespace(needle)) {
        var start: usize = 0;
        while (foldIndex(hay, needle, cs, start)) |i| {
            const before_ok = i == 0 or !isWordChar(hay[i - 1]);
            const after = i + needle.len;
            const after_ok = after == hay.len or !isWordChar(hay[after]);
            if (before_ok and after_ok) return true;
            start = i + 1;
        }
        return false;
    }
    return foldIndex(hay, needle, cs, 0) != null;
}

fn matchText(needle: []const u8, texts: []const []const u8, cs: bool, ww: bool) bool {
    for (texts) |t| {
        if (textMatches(t, needle, cs, ww)) return true;
    }
    return false;
}

fn matchKey(raw: []const u8, scan: []const []const u8, recurse: []const []const u8, cs: bool, ww: bool) bool {
    const key = std.mem.trim(u8, raw, " \t\r\n");
    if (key.len == 0) return false;
    return matchText(key, scan, cs, ww) or matchText(key, recurse, cs, ww);
}

fn matchAnyKey(keys: []const []const u8, scan: []const []const u8, recurse: []const []const u8, cs: bool, ww: bool) bool {
    for (keys) |k| {
        if (matchKey(k, scan, recurse, cs, ww)) return true;
    }
    return false;
}

/// The four stock selective logics over the secondary keys (world-info.js:4829). An empty
/// secondary key matches nothing, which fails and_all and never satisfies and_any, as stock.
fn selectiveOk(e: Entry, scan: []const []const u8, recurse: []const []const u8, cs: bool, ww: bool) bool {
    var any = false;
    var all = true;
    for (e.keysecondary) |k| {
        if (matchKey(k, scan, recurse, cs, ww)) any = true else all = false;
    }
    return switch (e.selective_logic) {
        .and_any => any,
        .not_all => !all,
        .not_any => !any,
        .and_all => all,
    };
}

/// The scan window an entry's own scanDepth selects (stock buffer.get :281): a null scanDepth uses
/// the skew-widened global depth, a depth <= 0 scans no chat (recursion buffer only).
fn entryScan(e: Entry, history: []const []const u8, global_depth: i64) []const []const u8 {
    const d = e.scan_depth orelse global_depth;
    const eff: usize = if (d <= 0) 0 else @min(@as(usize, @intCast(d)), history.len);
    return history[history.len - eff ..];
}

/// Stock WorldInfoBuffer.getScore (world-info.js:429): the count of primary + secondary key hits in
/// the entry's scan window. No primary keys scores 0; only and_any/and_all fold the secondary count.
fn getScore(e: Entry, scan: []const []const u8, recurse: []const []const u8, cs: bool, ww: bool) i64 {
    if (e.keys.len == 0) return 0;
    var primary: i64 = 0;
    for (e.keys) |k| {
        if (matchKey(k, scan, recurse, cs, ww)) primary += 1;
    }
    if (e.keysecondary.len == 0) return primary;
    var secondary: i64 = 0;
    for (e.keysecondary) |k| {
        if (matchKey(k, scan, recurse, cs, ww)) secondary += 1;
    }
    return switch (e.selective_logic) {
        .and_any => primary + secondary,
        .and_all => if (secondary == @as(i64, @intCast(e.keysecondary.len))) primary + secondary else primary,
        else => primary,
    };
}

/// Parsed @@decorators plus the content with the decorator lines stripped (stock parseDecorators
/// world-info.js:4538). `content` is a suffix subslice of the input. Only @@activate / @@dont_activate
/// (KNOWN_DECORATORS) are recognized, tested by EXACT string equality as stock's decorators.includes.
const Decor = struct { activate: bool, dont_activate: bool, content: []const u8 };

fn isKnownDecorator(line: []const u8) bool {
    const d = if (std.mem.startsWith(u8, line, "@@@")) line[1..] else line;
    return std.mem.startsWith(u8, d, "@@activate") or std.mem.startsWith(u8, d, "@@dont_activate");
}

fn parseDecorators(content: []const u8) Decor {
    if (!std.mem.startsWith(u8, content, "@@")) return .{ .activate = false, .dont_activate = false, .content = content };
    var activate_dec = false;
    var dont_activate = false;
    var fallbacked = false;
    var offset: usize = 0;
    // Stock init: newContent = content, so an all-@@ body strips to nothing (stays full content).
    var stripped = content;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            if (std.mem.startsWith(u8, line, "@@@") and !fallbacked) {
                offset += line.len + 1;
                continue;
            }
            if (isKnownDecorator(line)) {
                const d = if (std.mem.startsWith(u8, line, "@@@")) line[1..] else line;
                if (std.mem.eql(u8, d, "@@activate")) activate_dec = true;
                if (std.mem.eql(u8, d, "@@dont_activate")) dont_activate = true;
                fallbacked = false;
            } else {
                fallbacked = true;
            }
            offset += line.len + 1;
        } else {
            stripped = content[offset..];
            break;
        }
    }
    return .{ .activate = activate_dec, .dont_activate = dont_activate, .content = stripped };
}

fn listContains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, item)) return true;
    }
    return false;
}

fn listsIntersect(xs: []const []const u8, ys: []const []const u8) bool {
    for (xs) |x| {
        if (listContains(ys, x)) return true;
    }
    return false;
}

/// The scan texts an entry matches its keys against: its own chat window (entryScan) plus any gated,
/// non-empty extended sources (stock buffer.get :300-317). Extended sources join only when the entry's
/// resolved depth is > 0 (stock returns '' for depth <= startDepth, scanning nothing). Allocates only
/// when at least one extended source applies; otherwise returns the window subslice directly.
fn entryScanFull(a: Allocator, e: Entry, history: []const []const u8, global_depth: i64, params: Params) Allocator.Error![]const []const u8 {
    const window = entryScan(e, history, global_depth);
    const d = e.scan_depth orelse global_depth;
    if (d <= 0) return window;
    const srcs = [_]struct { on: bool, text: []const u8 }{
        .{ .on = e.match_persona_description, .text = params.persona_description },
        .{ .on = e.match_character_description, .text = params.character_description },
        .{ .on = e.match_character_personality, .text = params.character_personality },
        .{ .on = e.match_character_depth_prompt, .text = params.character_depth_prompt },
        .{ .on = e.match_scenario, .text = params.scenario },
        .{ .on = e.match_creator_notes, .text = params.creator_notes },
    };
    var extra: usize = 0;
    for (srcs) |s| {
        if (s.on and s.text.len > 0) extra += 1;
    }
    if (extra == 0) return window;
    const out = try a.alloc([]const u8, window.len + extra);
    @memcpy(out[0..window.len], window);
    var j = window.len;
    for (srcs) |s| {
        if (s.on and s.text.len > 0) {
            out[j] = s.text;
            j += 1;
        }
    }
    return out;
}

const ws_chars = " \t\n\r\x0b\x0c";

/// Prunes `newly` to one winner per inclusion group (stock filterByInclusionGroups :5266). Buckets
/// the group-carrying candidates by each comma-split token, runs the timed-effects filter then the
/// group-scoring pre-filter, then per group applies: already-activated wipe, single-member skip,
/// groupOverride prio, weighted random. A group with a sticky member skips scoring + selection (the
/// sticky members force the group). Mutates `newly` in place.
fn filterByInclusionGroups(
    a: Allocator,
    params: Params,
    newly: *std.ArrayList(usize),
    activated: []const usize,
    history: []const []const u8,
    global_depth: i64,
    rec_view: []const []const u8,
    sticky_active: []const bool,
    cooldown_active: []const bool,
    delay_active: []const bool,
) Allocator.Error!void {
    const entries = params.entries;
    const Bucket = struct { name: []const u8, members: std.ArrayList(usize) };
    var buckets: std.ArrayList(Bucket) = .empty;
    for (newly.items) |i| {
        const g = entries[i].group;
        if (g.len == 0) continue;
        // Stock split(/,\s*/): comma delimits and the whitespace after each comma is consumed, so
        // only tokens past the first are left-trimmed; a trailing space before a comma stays.
        var it = std.mem.splitScalar(u8, g, ',');
        var first = true;
        while (it.next()) |piece| {
            const tok = if (first) piece else std.mem.trimStart(u8, piece, ws_chars);
            first = false;
            if (tok.len == 0) continue;
            const b = for (buckets.items) |*b| {
                if (std.mem.eql(u8, b.name, tok)) break b;
            } else blk: {
                try buckets.append(a, .{ .name = tok, .members = .empty });
                break :blk &buckets.items[buckets.items.len - 1];
            };
            try b.members.append(a, i);
        }
    }
    if (buckets.items.len == 0) return;

    var removed = try a.alloc(bool, entries.len);
    @memset(removed, false);

    // filterGroupsByTimedEffects (:5215): a group with any sticky member keeps only its sticky
    // members and forces them (they skip scoring + selection); cooldown/delay members are removed.
    // Cooldown/delay members are already gate-suppressed, so their removal here is defensive parity.
    const has_sticky = try a.alloc(bool, buckets.items.len);
    @memset(has_sticky, false);
    for (buckets.items, 0..) |*b, bi| {
        for (b.members.items) |m| {
            if (sticky_active[m]) {
                has_sticky[bi] = true;
                break;
            }
        }
        if (has_sticky[bi]) {
            for (b.members.items) |m| {
                if (!sticky_active[m]) removed[m] = true;
            }
        }
        for (b.members.items) |m| {
            if (cooldown_active[m] or delay_active[m]) removed[m] = true;
        }
    }

    // filterGroupsByScoring (:5171): drop scored members below the group's max score. Gated per group
    // on world_info_use_group_scoring or any member carrying useGroupScoring; unscored members stay.
    // Skips a sticky-forced group (:5181).
    for (buckets.items, 0..) |*b, bi| {
        if (has_sticky[bi]) continue;
        var any_scored = params.use_group_scoring;
        for (b.members.items) |m| {
            if (entries[m].use_group_scoring orelse false) any_scored = true;
        }
        if (!any_scored) continue;
        const scores = try a.alloc(i64, b.members.items.len);
        var max_score: i64 = std.math.minInt(i64);
        for (b.members.items, 0..) |m, k| {
            const e = entries[m];
            scores[k] = getScore(e, try entryScanFull(a, e, history, global_depth, params), rec_view, e.case_sensitive orelse params.case_sensitive, e.match_whole_words orelse params.match_whole_words);
            if (scores[k] > max_score) max_score = scores[k];
        }
        var kept: std.ArrayList(usize) = .empty;
        for (b.members.items, 0..) |m, k| {
            const is_scored = entries[m].use_group_scoring orelse params.use_group_scoring;
            if (is_scored and scores[k] < max_score) removed[m] = true else try kept.append(a, m);
        }
        b.members = kept;
    }

    for (buckets.items, 0..) |*b, bi| {
        // A sticky-forced group is already resolved by the timed filter (:5303).
        if (has_sticky[bi]) continue;
        // Already activated in a prior pass: stock compares the activated entry's whole group string
        // to this single token (:5309, x.group === key), then force-drops every candidate here.
        var already = false;
        for (activated) |ai| {
            if (std.mem.eql(u8, entries[ai].group, b.name)) {
                already = true;
                break;
            }
        }
        if (already) {
            for (b.members.items) |m| removed[m] = true;
            continue;
        }
        if (b.members.items.len <= 1) continue;

        // groupOverride: the highest-order override entry wins outright (:5322, sortFn order-desc).
        var prio: std.ArrayList(usize) = .empty;
        for (b.members.items) |m| {
            if (entries[m].group_override) try prio.append(a, m);
        }
        if (prio.items.len > 0) {
            std.mem.sort(usize, prio.items, entries, orderDesc);
            const winner = prio.items[0];
            for (b.members.items) |m| {
                if (m != winner) removed[m] = true;
            }
            continue;
        }

        // Weighted random by groupWeight (:5330). A null rng rolls 0, so the first member wins.
        var total: i64 = 0;
        for (b.members.items) |m| total += entries[m].group_weight;
        const roll: f64 = if (params.rng) |rng| rng.float(f64) * @as(f64, @floatFromInt(total)) else 0.0;
        var cumulative: i64 = 0;
        var winner: ?usize = null;
        for (b.members.items) |m| {
            cumulative += entries[m].group_weight;
            if (roll <= @as(f64, @floatFromInt(cumulative))) {
                winner = m;
                break;
            }
        }
        if (winner) |w| {
            for (b.members.items) |m| {
                if (m != w) removed[m] = true;
            }
        }
    }

    var kept: std.ArrayList(usize) = .empty;
    for (newly.items) |i| {
        if (!removed[i]) try kept.append(a, i);
    }
    newly.* = kept;
}

const testing = std.testing;

fn te(uid: i64, keys: []const []const u8, content: []const u8) Entry {
    return .{
        .uid_key = "",
        .uid = uid,
        .keys = keys,
        .keysecondary = &.{},
        .selective_logic = .and_any,
        .content = content,
        .comment = "",
        .constant = false,
        .selective = false,
        .disable = false,
        .order = 100,
        .position = .before,
        .depth = 4,
        .probability = 100,
        .use_probability = true,
        .outlet_name = "",
    };
}

test "a matching key activates its entry and a non-matching key does not" {
    const entries = [_]Entry{
        te(0, &.{ "dragon", "wyrm" }, "ALPHA"),
        te(1, &.{"zebra"}, "NEVER"),
    };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"The DRAGON sleeps."});
    defer act.deinit();
    try testing.expectEqualStrings("ALPHA", act.before);
    try testing.expect(std.mem.indexOf(u8, act.before, "NEVER") == null);
}

test "matching is case-insensitive ascii substring and trims key whitespace" {
    const entries = [_]Entry{te(0, &.{" GateKey "}, "A")};
    var hit = try activate(testing.allocator, .{ .entries = &entries }, &.{"found the gatekey today"});
    defer hit.deinit();
    try testing.expectEqualStrings("A", hit.before);
    var miss = try activate(testing.allocator, .{ .entries = &entries }, &.{"found the gate key today"});
    defer miss.deinit();
    try testing.expectEqualStrings("", miss.before);
}

test "scan depth bounds the window from the newest message" {
    const entries = [_]Entry{te(0, &.{"lighthouse"}, "A")};
    const history = [_][]const u8{ "the lighthouse looms", "hello", "more talk" };
    var out_of_window = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 2 }, &history);
    defer out_of_window.deinit();
    try testing.expectEqualStrings("", out_of_window.before);
    var in_window = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 3 }, &history);
    defer in_window.deinit();
    try testing.expectEqualStrings("A", in_window.before);
    var depth_zero = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 0 }, &history);
    defer depth_zero.deinit();
    try testing.expectEqualStrings("", depth_zero.before);
}

test "a constant entry fires with no key match and a disabled one never fires" {
    var constant = te(0, &.{}, "ALWAYS");
    constant.constant = true;
    var disabled = te(1, &.{"hello"}, "OFF");
    disabled.disable = true;
    var disabled_constant = te(2, &.{}, "OFF2");
    disabled_constant.constant = true;
    disabled_constant.disable = true;
    const entries = [_]Entry{ constant, disabled, disabled_constant };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"hello"});
    defer act.deinit();
    try testing.expectEqualStrings("ALWAYS", act.before);
}

test "the four selective logics gate on the secondary keys" {
    const Case = struct { logic: wi.Logic, expect_hit: bool };
    // Scan text carries "red" but not "blue"; secondary = [red, blue] -> any=true, all=false.
    const cases = [_]Case{
        .{ .logic = .and_any, .expect_hit = true },
        .{ .logic = .not_all, .expect_hit = true },
        .{ .logic = .not_any, .expect_hit = false },
        .{ .logic = .and_all, .expect_hit = false },
    };
    for (cases) |c| {
        var e = te(0, &.{"dragon"}, "S");
        e.selective = true;
        e.keysecondary = &.{ "red", "blue" };
        e.selective_logic = c.logic;
        const entries = [_]Entry{e};
        var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"a red dragon"});
        defer act.deinit();
        try testing.expectEqualStrings(if (c.expect_hit) "S" else "", act.before);
    }
}

test "recursion activates an entry keyed only by another entry's content, gated by the flag" {
    const entries = [_]Entry{
        te(0, &.{"dragon"}, "the ember hoard"),
        te(1, &.{"ember"}, "SECOND"),
    };
    var on = try activate(testing.allocator, .{ .entries = &entries, .recursive = true }, &.{"a dragon"});
    defer on.deinit();
    // Both share the default order, so the tie reverses (stock's unshift): the later-activated SECOND
    // sits ahead of the entry that seeded it.
    try testing.expectEqualStrings("SECOND\nthe ember hoard", on.before);
    var off = try activate(testing.allocator, .{ .entries = &entries, .recursive = false }, &.{"a dragon"});
    defer off.deinit();
    try testing.expectEqualStrings("the ember hoard", off.before);
}

test "the budget cap drops the lowest-priority entries first and stops activation" {
    // Priority = list order; join order = entry order ascending. keep2(order 50) joins before
    // keep1(order 90) yet outranks nothing: the third candidate is what the cap sheds.
    var keep1 = te(0, &.{}, "AAAAAAAAAA");
    keep1.constant = true;
    keep1.order = 90;
    var keep2 = te(1, &.{}, "BBBBBBBBBB");
    keep2.constant = true;
    keep2.order = 50;
    var drop = te(2, &.{}, "CCCCCCCCCC");
    drop.constant = true;
    drop.order = 10;
    const entries = [_]Entry{ keep1, keep2, drop };
    var act = try activate(testing.allocator, .{ .entries = &entries, .budget_chars = 25 }, &.{});
    defer act.deinit();
    try testing.expectEqualStrings("BBBBBBBBBB\nAAAAAAAAAA", act.before);
    var roomy = try activate(testing.allocator, .{ .entries = &entries, .budget_chars = 1000 }, &.{});
    defer roomy.deinit();
    try testing.expectEqualStrings("CCCCCCCCCC\nBBBBBBBBBB\nAAAAAAAAAA", roomy.before);
}

test "reaching the budget exactly overflows, one char under it does not" {
    var e = te(0, &.{}, "12345");
    e.constant = true;
    const entries = [_]Entry{e};
    var exact = try activate(testing.allocator, .{ .entries = &entries, .budget_chars = 6 }, &.{});
    defer exact.deinit();
    try testing.expectEqualStrings("", exact.before);
    var under = try activate(testing.allocator, .{ .entries = &entries, .budget_chars = 7 }, &.{});
    defer under.deinit();
    try testing.expectEqualStrings("12345", under.before);
}

test "probability entries roll the caller's rng with a fixed seed, once each" {
    var gated = te(0, &.{}, "MAYBE");
    gated.constant = true;
    gated.probability = 50;
    var sure = te(1, &.{}, "SURE");
    sure.constant = true;
    sure.probability = 50;
    sure.use_probability = false;
    const entries = [_]Entry{ gated, sure };

    // The engine consumes one float roll for the gated entry; mirror it to know the verdict.
    var mirror = std.Random.DefaultPrng.init(0x5eed);
    const expect_gated = mirror.random().float(f64) * 100.0 <= 50.0;

    var prng = std.Random.DefaultPrng.init(0x5eed);
    var act = try activate(testing.allocator, .{ .entries = &entries, .rng = prng.random() }, &.{});
    defer act.deinit();
    // Both entries share the default order, so the tie reverses to SURE (uid1) then MAYBE (uid0).
    const want = if (expect_gated) "SURE\nMAYBE" else "SURE";
    try testing.expectEqualStrings(want, act.before);

    var no_rng = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer no_rng.deinit();
    try testing.expectEqualStrings("SURE\nMAYBE", no_rng.before);
}

test "every position lands in its own slot and at_depth groups merge per depth" {
    const mk = struct {
        fn e(uid: i64, pos: wi.Position, depth: i64, order: i64, content: []const u8) Entry {
            var x = te(uid, &.{}, content);
            x.constant = true;
            x.position = pos;
            x.depth = depth;
            x.order = order;
            return x;
        }
    };
    var named_out = mk.e(9, .outlet, 4, 100, "OUT");
    named_out.outlet_name = "gate";
    const entries = [_]Entry{
        mk.e(0, .before, 4, 100, "B"),
        mk.e(1, .after, 4, 100, "A"),
        mk.e(2, .an_top, 4, 100, "NT"),
        mk.e(3, .an_bottom, 4, 100, "NB"),
        mk.e(4, .em_top, 4, 100, "ET"),
        mk.e(5, .em_bottom, 4, 100, "EB"),
        mk.e(6, .at_depth, 2, 200, "D2-late"),
        mk.e(7, .at_depth, 2, 100, "D2-early"),
        mk.e(8, .at_depth, 0, 100, "D0"),
        named_out,
    };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer act.deinit();
    try testing.expectEqualStrings("B", act.before);
    try testing.expectEqualStrings("A", act.after);
    try testing.expectEqualStrings("NT", act.an_top);
    try testing.expectEqualStrings("NB", act.an_bottom);
    try testing.expectEqual(@as(usize, 1), act.em_top.len);
    try testing.expectEqualStrings("ET", act.em_top[0]);
    try testing.expectEqualStrings("EB", act.em_bottom[0]);
    try testing.expectEqual(@as(usize, 2), act.at_depth.len);
    try testing.expectEqual(@as(i64, 2), act.at_depth[0].depth);
    try testing.expectEqualStrings("D2-early\nD2-late", act.at_depth[0].content);
    try testing.expectEqual(@as(i64, 0), act.at_depth[1].depth);
    try testing.expectEqualStrings("D0", act.at_depth[1].content);
    try testing.expectEqual(@as(usize, 1), act.outlets.len);
    try testing.expectEqualStrings("gate", act.outlets[0].name);
    try testing.expectEqualStrings("OUT", act.outlets[0].content);
}

test "outlet entries group per name via push, and a nameless one is skipped" {
    const mk = struct {
        fn e(uid: i64, name: []const u8, order: i64, content: []const u8) Entry {
            var x = te(uid, &.{}, content);
            x.constant = true;
            x.position = .outlet;
            x.outlet_name = name;
            x.order = order;
            return x;
        }
    };
    const entries = [_]Entry{
        mk.e(0, "judge", 200, "J-LATE"),
        mk.e(1, "narrator", 100, "N"),
        mk.e(2, "judge", 100, "J-EARLY"),
        mk.e(3, "", 100, "NAMELESS"),
    };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer act.deinit();
    // Groups keyed in descending-scan first-seen order (judge's order-200 entry leads), and outlet
    // content is push (:5133), so within judge the descending scan keeps J-LATE ahead of J-EARLY.
    try testing.expectEqual(@as(usize, 2), act.outlets.len);
    try testing.expectEqualStrings("judge", act.outlets[0].name);
    try testing.expectEqualStrings("J-LATE\nJ-EARLY", act.outlets[0].content);
    try testing.expectEqualStrings("narrator", act.outlets[1].name);
    try testing.expectEqualStrings("N", act.outlets[1].content);
    try testing.expectEqualStrings("", act.before);
}

test "an entry without keys and without constant never fires" {
    const entries = [_]Entry{te(0, &.{}, "GHOST")};
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"anything"});
    defer act.deinit();
    try testing.expectEqualStrings("", act.before);
}

test "caseSensitive gates on exact case per entry and via the global default" {
    var sens = te(0, &.{"GLADE"}, "S");
    sens.case_sensitive = true;
    var fold = te(1, &.{"GLADE"}, "F");
    fold.case_sensitive = false;
    const entries = [_]Entry{ sens, fold };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"the glade"});
    defer act.deinit();
    // The case-sensitive "GLADE" misses lowercase "glade"; the folding entry matches.
    try testing.expectEqualStrings("F", act.before);

    // A null per-entry value falls back to the global (params.case_sensitive).
    const g_entries = [_]Entry{te(2, &.{"GLADE"}, "G")};
    var g = try activate(testing.allocator, .{ .entries = &g_entries, .case_sensitive = true }, &.{"the glade"});
    defer g.deinit();
    try testing.expectEqualStrings("", g.before);
}

test "matchWholeWords bounds a single-word key, a multi-word key stays substring" {
    var whole = te(0, &.{"cat"}, "W");
    whole.match_whole_words = true;
    const one = [_]Entry{whole};
    var miss = try activate(testing.allocator, .{ .entries = &one }, &.{"concatenate"});
    defer miss.deinit();
    try testing.expectEqualStrings("", miss.before);
    var hit = try activate(testing.allocator, .{ .entries = &one }, &.{"the cat sat"});
    defer hit.deinit();
    try testing.expectEqualStrings("W", hit.before);

    // Stock: a multi-word key (keyWords.length > 1) ignores boundaries and plain-contains.
    var multi = te(1, &.{"safe haven"}, "M");
    multi.match_whole_words = true;
    const two = [_]Entry{multi};
    var m = try activate(testing.allocator, .{ .entries = &two }, &.{"a safe havenland"});
    defer m.deinit();
    try testing.expectEqualStrings("M", m.before);
}

test "per-entry scanDepth bounds an entry's own key window" {
    var shallow = te(0, &.{"old"}, "S");
    shallow.scan_depth = 1;
    var deep = te(1, &.{"old"}, "D");
    deep.scan_depth = 2;
    const entries = [_]Entry{ shallow, deep };
    // Oldest-first history; "old" appears only in the older message.
    var act = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 5 }, &.{ "mentions old", "newest" });
    defer act.deinit();
    // The scanDepth-1 entry sees only "newest" (no match); the scanDepth-2 entry sees both.
    try testing.expectEqualStrings("D", act.before);
}

test "atDepth entries at one depth split into separate groups by role" {
    var sys = te(0, &.{}, "SYS");
    sys.constant = true;
    sys.position = .at_depth;
    sys.depth = 3;
    sys.role = 0;
    var usr = te(1, &.{}, "USR");
    usr.constant = true;
    usr.position = .at_depth;
    usr.depth = 3;
    usr.role = 1;
    const entries = [_]Entry{ sys, usr };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer act.deinit();
    try testing.expectEqual(@as(usize, 2), act.at_depth.len);
    var saw_sys = false;
    var saw_usr = false;
    for (act.at_depth) |grp| {
        if (grp.role == 0) {
            saw_sys = true;
            try testing.expectEqualStrings("SYS", grp.content);
        }
        if (grp.role == 1) {
            saw_usr = true;
            try testing.expectEqualStrings("USR", grp.content);
        }
    }
    try testing.expect(saw_sys and saw_usr);
}

test "a delayUntilRecursion entry fires only on a recursion pass" {
    const seed = te(0, &.{"dragon"}, "the hoard");
    var delayed = te(1, &.{"dragon"}, "DELAYED");
    delayed.delay_until_recursion = 1;
    const entries = [_]Entry{ seed, delayed };
    // With recursion, the seed's pass opens a recursion scan where the delayed entry may fire.
    var on = try activate(testing.allocator, .{ .entries = &entries, .recursive = true }, &.{"a dragon"});
    defer on.deinit();
    try testing.expect(std.mem.indexOf(u8, on.before, "DELAYED") != null);
    // Without a recursion pass the delayed entry is suppressed on the initial scan and never fires.
    var off = try activate(testing.allocator, .{ .entries = &entries, .recursive = false }, &.{"a dragon"});
    defer off.deinit();
    try testing.expect(std.mem.indexOf(u8, off.before, "DELAYED") == null);
    try testing.expect(std.mem.indexOf(u8, off.before, "the hoard") != null);
}

test "an excludeRecursion entry does not fire on a recursion pass" {
    const seed = te(0, &.{"dragon"}, "the ember");
    var excl = te(1, &.{"ember"}, "EXCLUDED");
    excl.exclude_recursion = true;
    const entries = [_]Entry{ seed, excl };
    var act = try activate(testing.allocator, .{ .entries = &entries, .recursive = true }, &.{"a dragon"});
    defer act.deinit();
    try testing.expect(std.mem.indexOf(u8, act.before, "EXCLUDED") == null);
    // The same entry without the flag matches the seed's content on recursion and fires.
    const incl = te(2, &.{"ember"}, "INCLUDED");
    const ctrl = [_]Entry{ seed, incl };
    var act2 = try activate(testing.allocator, .{ .entries = &ctrl, .recursive = true }, &.{"a dragon"});
    defer act2.deinit();
    try testing.expect(std.mem.indexOf(u8, act2.before, "INCLUDED") != null);
}

test "a preventRecursion entry keeps its content out of the recursion scan" {
    var prevent = te(0, &.{"dragon"}, "the ember");
    prevent.prevent_recursion = true;
    const second = te(1, &.{"ember"}, "SECOND");
    const entries = [_]Entry{ prevent, second };
    var act = try activate(testing.allocator, .{ .entries = &entries, .recursive = true }, &.{"a dragon"});
    defer act.deinit();
    try testing.expect(std.mem.indexOf(u8, act.before, "SECOND") == null);
    try testing.expect(std.mem.indexOf(u8, act.before, "the ember") != null);
    // Feeding the same content without the flag lets SECOND activate off the recursion buffer.
    const feed = te(0, &.{"dragon"}, "the ember");
    const ctrl = [_]Entry{ feed, second };
    var act2 = try activate(testing.allocator, .{ .entries = &ctrl, .recursive = true }, &.{"a dragon"});
    defer act2.deinit();
    try testing.expect(std.mem.indexOf(u8, act2.before, "SECOND") != null);
}

test "an ignoreBudget entry activates past an overflowed budget" {
    var big = te(0, &.{}, "AAAAAAAAAA");
    big.constant = true;
    var ignored = te(1, &.{}, "KEEP");
    ignored.constant = true;
    ignored.ignore_budget = true;
    ignored.order = 50;
    const entries = [_]Entry{ big, ignored };
    // The 10-char entry overflows a 5-char budget; the ignoreBudget entry still lands.
    var act = try activate(testing.allocator, .{ .entries = &entries, .budget_chars = 5 }, &.{});
    defer act.deinit();
    try testing.expectEqualStrings("KEEP", act.before);
}

test "min_activations widens the scan until a deeper match activates" {
    const entries = [_]Entry{te(0, &.{"lighthouse"}, "DEEP")};
    // Oldest-first; "lighthouse" is only in the oldest message, out of the depth-1 window.
    const history = [_][]const u8{ "the lighthouse looms", "chatter", "more" };
    var with_min = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .min_activations = 1 }, &history);
    defer with_min.deinit();
    try testing.expectEqualStrings("DEEP", with_min.before);
    var without = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1 }, &history);
    defer without.deinit();
    try testing.expectEqualStrings("", without.before);
    // A depth-max cap stops the widening before the oldest message is ever in the window.
    var capped = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .min_activations = 1, .min_activations_depth_max = 1 }, &history);
    defer capped.deinit();
    try testing.expectEqualStrings("", capped.before);
}

test "groupOverride activates the highest-order override entry and drops the rest of its group" {
    var plain = te(0, &.{}, "PLAIN");
    plain.constant = true;
    plain.order = 100;
    plain.group = "g";
    var win = te(1, &.{}, "WIN");
    win.constant = true;
    win.order = 90;
    win.group = "g";
    win.group_override = true;
    var lose = te(2, &.{}, "LOSE");
    lose.constant = true;
    lose.order = 50;
    lose.group = "g";
    lose.group_override = true;
    const entries = [_]Entry{ plain, win, lose };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer act.deinit();
    // The order-90 override outranks the order-50 override; the non-override order-100 entry loses too.
    try testing.expectEqualStrings("WIN", act.before);
}

test "weighted random picks the group winner the seeded roll selects" {
    var e0 = te(0, &.{}, "FIRST");
    e0.constant = true;
    e0.order = 100;
    e0.group = "g";
    e0.group_weight = 50;
    var e1 = te(1, &.{}, "SECOND");
    e1.constant = true;
    e1.order = 90;
    e1.group = "g";
    e1.group_weight = 50;
    const entries = [_]Entry{ e0, e1 };

    // The filter consumes exactly one float (the weighted roll); mirror it to know the winner.
    var mirror = std.Random.DefaultPrng.init(0x9317);
    const roll = mirror.random().float(f64) * 100.0;
    const want: []const u8 = if (roll <= 50.0) "FIRST" else "SECOND";

    var prng = std.Random.DefaultPrng.init(0x9317);
    var act = try activate(testing.allocator, .{ .entries = &entries, .rng = prng.random() }, &.{});
    defer act.deinit();
    try testing.expectEqualStrings(want, act.before);
}

test "a group already activated on a prior pass drops the group's later recursion candidates" {
    const seed = te(0, &.{"dragon"}, "the ember hoard");
    var later = te(1, &.{"ember"}, "SECOND");
    later.order = 50;
    // Same group as the seed: the recursion candidate is force-dropped as already-activated.
    var same = seed;
    same.group = "g";
    var later_same = later;
    later_same.group = "g";
    const grouped = [_]Entry{ same, later_same };
    var act = try activate(testing.allocator, .{ .entries = &grouped, .recursive = true }, &.{"a dragon"});
    defer act.deinit();
    try testing.expect(std.mem.indexOf(u8, act.before, "SECOND") == null);
    try testing.expect(std.mem.indexOf(u8, act.before, "the ember hoard") != null);

    // A different group leaves the recursion candidate free to activate.
    var later_other = later;
    later_other.group = "h";
    var same_h = seed;
    same_h.group = "g";
    const split = [_]Entry{ same_h, later_other };
    var act2 = try activate(testing.allocator, .{ .entries = &split, .recursive = true }, &.{"a dragon"});
    defer act2.deinit();
    try testing.expect(std.mem.indexOf(u8, act2.before, "SECOND") != null);
}

test "a multi-group override entry wins every group it belongs to" {
    var x = te(0, &.{}, "X");
    x.constant = true;
    x.order = 100;
    x.group = "g1, g2";
    x.group_override = true;
    var y = te(1, &.{}, "Y");
    y.constant = true;
    y.order = 90;
    y.group = "g1";
    var z = te(2, &.{}, "Z");
    z.constant = true;
    z.order = 80;
    z.group = "g2";
    const entries = [_]Entry{ x, y, z };
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer act.deinit();
    // X sits in both g1 and g2 buckets and wins each, so Y and Z are both dropped.
    try testing.expectEqualStrings("X", act.before);
}

test "useGroupScoring keeps only the higher-scoring entry of a group" {
    var hi = te(0, &.{ "dragon", "wyrm" }, "HI");
    hi.order = 100;
    hi.group = "g";
    var lo = te(1, &.{"dragon"}, "LO");
    lo.order = 90;
    lo.group = "g";
    const entries = [_]Entry{ hi, lo };
    // Scan hits both of hi's keys (score 2) but only lo's one key (score 1); scoring drops lo.
    var act = try activate(testing.allocator, .{ .entries = &entries, .use_group_scoring = true }, &.{"a dragon wyrm appears"});
    defer act.deinit();
    try testing.expect(std.mem.indexOf(u8, act.before, "HI") != null);
    try testing.expect(std.mem.indexOf(u8, act.before, "LO") == null);
}

test "inclusion group filter cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var a1 = te(0, &.{ "dragon", "wyrm" }, "A1");
            a1.constant = true;
            a1.group = "g1, g2";
            a1.group_override = true;
            var a2 = te(1, &.{"dragon"}, "A2");
            a2.group = "g1";
            a2.group_weight = 30;
            var a3 = te(2, &.{}, "A3");
            a3.constant = true;
            a3.group = "g2";
            a3.use_group_scoring = true;
            const entries = [_]Entry{ a1, a2, a3 };
            var prng = std.Random.DefaultPrng.init(0x1234);
            var act = try activate(alloc, .{ .entries = &entries, .rng = prng.random(), .use_group_scoring = true }, &.{"a dragon wyrm"});
            act.deinit();
        }
    }.run, .{});
}

test "activate cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var recurse_a = te(0, &.{"dragon"}, "the ember hoard");
            recurse_a.position = .at_depth;
            var b = te(1, &.{"ember"}, "SECOND");
            b.position = .em_top;
            var c = te(2, &.{}, "CONST");
            c.constant = true;
            var d = te(3, &.{}, "OUT");
            d.constant = true;
            d.position = .outlet;
            d.outlet_name = "gate";
            var delayed = te(4, &.{"dragon"}, "LATE");
            delayed.delay_until_recursion = 2;
            const entries = [_]Entry{ recurse_a, b, c, d, delayed };
            var act = try activate(alloc, .{ .entries = &entries, .recursive = true, .min_activations = 3 }, &.{"a dragon"});
            act.deinit();
        }
    }.run, .{});
}

test "activate never panics on arbitrary scan bytes" {
    var prng = std.Random.DefaultPrng.init(0xacc07);
    const rand = prng.random();
    var buf: [64]u8 = undefined;
    const entries = [_]Entry{ te(0, &.{"a"}, "X"), te(1, &.{"\x01"}, "Y") };
    for (0..2000) |_| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        var act = try activate(testing.allocator, .{ .entries = &entries }, &.{buf[0..len]});
        act.deinit();
    }
}

// ---- timed effects (sticky / cooldown / delay) -------------------------------------------------

fn tt(uid: i64, keys: []const []const u8, content: []const u8, world: []const u8) Entry {
    var e = te(uid, keys, content);
    e.world = world;
    return e;
}

/// Deep-copies a timed state into `a` so a send's timed_out can be threaded after its Activation
/// (and its arena) is freed. Models the chat-metadata persist/reload the lead wires.
fn cloneTimed(a: Allocator, src: TimedState) !TimedState {
    const s = try a.alloc(Timed, src.sticky.len);
    for (src.sticky, 0..) |t, i| s[i] = .{ .key = try a.dupe(u8, t.key), .effect = t.effect };
    const c = try a.alloc(Timed, src.cooldown.len);
    for (src.cooldown, 0..) |t, i| c[i] = .{ .key = try a.dupe(u8, t.key), .effect = t.effect };
    return .{ .sticky = s, .cooldown = c };
}

test "a sticky entry stays active for its window after triggering, then drops" {
    var e = tt(0, &.{"dragon"}, "S", "w");
    e.sticky = 2;
    const entries = [_]Entry{e};
    // scan_depth 1 scans only the newest message, so once the keyword scrolls out only sticky can fire.
    var s1 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1 }, &.{"a dragon"});
    defer s1.deinit();
    try testing.expectEqualStrings("S", s1.before);

    var s2 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .timed_in = s1.timed_out }, &.{ "a dragon", "boring" });
    defer s2.deinit();
    // Newest is "boring" (no key), yet the entry is still sticky-active from send 1.
    try testing.expectEqualStrings("S", s2.before);

    var s3 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .timed_in = s2.timed_out }, &.{ "a dragon", "boring", "dull" });
    defer s3.deinit();
    // chat_len 3 reaches end (1 + 2): the sticky effect drops and the key no longer matches.
    try testing.expectEqualStrings("", s3.before);
}

test "a cooldown entry is suppressed for its window after triggering" {
    var e = tt(0, &.{"dragon"}, "C", "w");
    e.cooldown = 2;
    const entries = [_]Entry{e};
    // The key matches every send; only the cooldown can suppress it.
    var s1 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1 }, &.{"a dragon"});
    defer s1.deinit();
    try testing.expectEqualStrings("C", s1.before);

    var s2 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .timed_in = s1.timed_out }, &.{ "a dragon", "a dragon" });
    defer s2.deinit();
    // On cooldown (start 1, end 3) at chat_len 2, so suppressed despite the key match.
    try testing.expectEqualStrings("", s2.before);

    var s3 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .timed_in = s2.timed_out }, &.{ "a dragon", "a dragon", "a dragon" });
    defer s3.deinit();
    // chat_len 3 reaches end: cooldown drops and the entry fires again.
    try testing.expectEqualStrings("C", s3.before);
}

test "a sticky ending starts the entry's cooldown from the sticky-end message" {
    var e = tt(0, &.{"dragon"}, "S", "w");
    e.sticky = 3;
    e.cooldown = 1;
    const entries = [_]Entry{e};
    // The activation-time cooldown (start 1, end 2) expires long before the sticky (end 4); only a
    // cooldown re-armed at the sticky-end message can suppress send 4.
    var s1 = try activate(testing.allocator, .{ .entries = &entries }, &.{"a dragon"});
    defer s1.deinit();
    var s2 = try activate(testing.allocator, .{ .entries = &entries, .timed_in = s1.timed_out }, &.{ "a dragon", "x" });
    defer s2.deinit();
    var s3 = try activate(testing.allocator, .{ .entries = &entries, .timed_in = s2.timed_out }, &.{ "a dragon", "x", "y" });
    defer s3.deinit();
    var s4 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .timed_in = s3.timed_out }, &.{ "a dragon", "x", "y", "z" });
    defer s4.deinit();
    // Sticky ends at chat_len 4; the entry is suppressed by the fresh cooldown, and that cooldown's
    // effect starts at message 4 with the protected flag onEnded sets.
    try testing.expectEqualStrings("", s4.before);
    try testing.expectEqual(@as(usize, 1), s4.timed_out.cooldown.len);
    try testing.expectEqual(@as(i64, 4), s4.timed_out.cooldown[0].effect.start);
    try testing.expect(s4.timed_out.cooldown[0].effect.protected);
}

test "a delay entry is suppressed until the chat length reaches its delay" {
    var e = tt(0, &.{"dragon"}, "D", "w");
    e.delay = 3;
    const entries = [_]Entry{e};
    // delay is not persisted; it reads history.len directly, so two independent sends prove it.
    var short = try activate(testing.allocator, .{ .entries = &entries }, &.{ "a dragon", "a dragon" });
    defer short.deinit();
    try testing.expectEqualStrings("", short.before);
    var reached = try activate(testing.allocator, .{ .entries = &entries }, &.{ "a dragon", "a dragon", "a dragon" });
    defer reached.deinit();
    try testing.expectEqualStrings("D", reached.before);
}

test "a sticky member forces its inclusion group over a higher-order sibling" {
    var a = tt(0, &.{"alpha"}, "ALPHACONTENT", "w");
    a.order = 100;
    a.group = "g";
    var b = tt(1, &.{"beta"}, "BETACONTENT", "w");
    b.order = 50;
    b.group = "g";
    b.sticky = 2;
    const entries = [_]Entry{ a, b };
    // Send 1: only B's key is present, so B alone activates and becomes sticky.
    var s1 = try activate(testing.allocator, .{ .entries = &entries }, &.{"a beta"});
    defer s1.deinit();
    try testing.expectEqualStrings("BETACONTENT", s1.before);
    // Send 2: both keys present. A outranks B by order, but B is sticky and forces the group.
    var s2 = try activate(testing.allocator, .{ .entries = &entries, .timed_in = s1.timed_out }, &.{ "a beta", "an alpha and beta" });
    defer s2.deinit();
    try testing.expectEqualStrings("BETACONTENT", s2.before);
}

test "timed_out round-trips through a persist and reload to the same decision" {
    var e = tt(0, &.{"dragon"}, "S", "w");
    e.sticky = 2;
    const entries = [_]Entry{e};
    var persist_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer persist_arena.deinit();

    var s1 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1 }, &.{"a dragon"});
    // Clone timed_out, then free s1 (and its arena) entirely before the reload send.
    const persisted = try cloneTimed(persist_arena.allocator(), s1.timed_out);
    s1.deinit();

    var s2 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .timed_in = persisted }, &.{ "a dragon", "boring" });
    defer s2.deinit();
    // The reloaded sticky state still activates the entry with no live key match.
    try testing.expectEqualStrings("S", s2.before);
}

test "timed state writes the stock chat_metadata shape and parses back through JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = TimedState{
        .sticky = &.{.{ .key = "w.0", .effect = .{ .hash = 0xFFFFFFFFFFFFFFF0, .start = 1, .end = 3, .protected = false } }},
        .cooldown = &.{.{ .key = "w.1", .effect = .{ .hash = 42, .start = 2, .end = 5, .protected = true } }},
    };
    const bytes = try std.json.Stringify.valueAlloc(a, try writeTimedState(a, ts), .{});
    // The shape is stock's: sticky/cooldown objects keyed by "world.uid".
    try testing.expect(std.mem.indexOf(u8, bytes, "\"sticky\":{\"w.0\":") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"cooldown\":{\"w.1\":") != null);

    const back = try readTimedState(a, try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}));
    try testing.expectEqual(@as(usize, 1), back.sticky.len);
    try testing.expectEqualStrings("w.0", back.sticky[0].key);
    // A u64 hash past i64 range survives the number_string round-trip.
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFF0), back.sticky[0].effect.hash);
    try testing.expectEqual(@as(i64, 3), back.sticky[0].effect.end);
    try testing.expect(!back.sticky[0].effect.protected);
    try testing.expectEqual(@as(u64, 42), back.cooldown[0].effect.hash);
    try testing.expect(back.cooldown[0].effect.protected);
}

test "readTimedFromMetadata unwraps the header field and both readers tolerate junk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md =
        \\{"world_info":"Eldoria","timedWorldInfo":{"sticky":{"w.0":{"hash":7,"start":1,"end":3,"protected":false}},"cooldown":{}}}
    ;
    const ts = readTimedFromMetadata(a, md);
    try testing.expectEqual(@as(usize, 1), ts.sticky.len);
    try testing.expectEqualStrings("w.0", ts.sticky[0].key);
    try testing.expectEqual(@as(i64, 3), ts.sticky[0].effect.end);
    try testing.expectEqual(@as(usize, 0), ts.cooldown.len);
    // No field, wrong type, and outright junk all degrade to empty, never a crash.
    try testing.expectEqual(@as(usize, 0), readTimedFromMetadata(a, "{}").sticky.len);
    try testing.expectEqual(@as(usize, 0), readTimedFromMetadata(a, "not json").sticky.len);
    try testing.expectEqual(@as(usize, 0), readTimedFromJson(a, "").cooldown.len);
    // The bare-value reader takes the writeTimedState shape directly (no timedWorldInfo wrapper).
    const bare =
        \\{"sticky":{"w.1":{"hash":1,"start":0,"end":2,"protected":true}},"cooldown":{}}
    ;
    const bs = readTimedFromJson(a, bare);
    try testing.expectEqual(@as(usize, 1), bs.sticky.len);
    try testing.expect(bs.sticky[0].effect.protected);
}

test "timed_out survives a JSON persist and reload and drives the same sticky decision" {
    var e = tt(0, &.{"dragon"}, "S", "w");
    e.sticky = 2;
    const entries = [_]Entry{e};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s1 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1 }, &.{"a dragon"});
    const bytes = try std.json.Stringify.valueAlloc(a, try writeTimedState(a, s1.timed_out), .{});
    s1.deinit(); // free s1 and its arena; the JSON string is the only surviving state.

    const reloaded = try readTimedState(a, try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}));
    var s2 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .timed_in = reloaded }, &.{ "a dragon", "boring" });
    defer s2.deinit();
    // The reloaded sticky state fires the entry with no live key match, proving the wired path.
    try testing.expectEqualStrings("S", s2.before);
}

test "timed effects clean up on every allocation failure across a multi-send thread" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var e = tt(0, &.{"dragon"}, "S", "w");
            e.sticky = 2;
            e.cooldown = 2;
            const entries = [_]Entry{e};
            var s1 = try activate(alloc, .{ .entries = &entries, .scan_depth = 1 }, &.{"a dragon"});
            defer s1.deinit();
            var s2 = try activate(alloc, .{ .entries = &entries, .scan_depth = 1, .timed_in = s1.timed_out }, &.{ "a dragon", "boring", "dull" });
            s2.deinit();
        }
    }.run, .{});
}

// ---- chunk 4: characterFilter, triggers, decorators, extended scan sources ---------------------

test "parseDecorators recognizes known decorators by exact match and strips their lines" {
    {
        const d = parseDecorators("plain body");
        try testing.expect(!d.activate and !d.dont_activate);
        try testing.expectEqualStrings("plain body", d.content);
    }
    {
        const d = parseDecorators("@@activate\nbody line");
        try testing.expect(d.activate and !d.dont_activate);
        try testing.expectEqualStrings("body line", d.content);
    }
    {
        const d = parseDecorators("@@dont_activate\nx");
        try testing.expect(d.dont_activate and !d.activate);
        try testing.expectEqualStrings("x", d.content);
    }
    // A known decorator with a trailing argument is stripped but is NOT an exact match, so no flag.
    {
        const d = parseDecorators("@@activate foo\nbody");
        try testing.expect(!d.activate);
        try testing.expectEqualStrings("body", d.content);
    }
    // An unknown decorator sets fallbacked; a following known one still counts and the body strips.
    {
        const d = parseDecorators("@@unknown\n@@activate\nbody");
        try testing.expect(d.activate);
        try testing.expectEqualStrings("body", d.content);
    }
    {
        const d = parseDecorators("@@dont_activate\n@@activate\nbody");
        try testing.expect(d.activate and d.dont_activate);
        try testing.expectEqualStrings("body", d.content);
    }
    // @@@activate is escaped when not fallbacked: skipped, no flag, and the line is still stripped.
    {
        const d = parseDecorators("@@@activate\nbody");
        try testing.expect(!d.activate);
        try testing.expectEqualStrings("body", d.content);
    }
}

test "the @@activate decorator forces an entry in and its line is stripped from the content" {
    // No key match in the scan and not constant; only the decorator can fire it.
    const entries = [_]Entry{te(0, &.{"never"}, "@@activate\nFORCED")};
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{"unrelated text"});
    defer act.deinit();
    try testing.expectEqualStrings("FORCED", act.before);
}

test "the @@dont_activate decorator suppresses even a constant entry" {
    var e = te(0, &.{}, "@@dont_activate\nHIDDEN");
    e.constant = true;
    const entries = [_]Entry{e};
    var act = try activate(testing.allocator, .{ .entries = &entries }, &.{});
    defer act.deinit();
    try testing.expectEqualStrings("", act.before);
}

test "characterFilter includes or excludes an entry by character name" {
    var inc = te(0, &.{}, "INC");
    inc.constant = true;
    inc.char_filter_names = &.{"alice.png"};
    const one = [_]Entry{inc};
    var hit = try activate(testing.allocator, .{ .entries = &one, .chara_filename = "alice.png" }, &.{});
    defer hit.deinit();
    try testing.expectEqualStrings("INC", hit.before);
    var miss = try activate(testing.allocator, .{ .entries = &one, .chara_filename = "bob.png" }, &.{});
    defer miss.deinit();
    try testing.expectEqualStrings("", miss.before);

    var exc = te(1, &.{}, "EXC");
    exc.constant = true;
    exc.char_filter_names = &.{"alice.png"};
    exc.char_filter_exclude = true;
    const two = [_]Entry{exc};
    var exc_hit = try activate(testing.allocator, .{ .entries = &two, .chara_filename = "bob.png" }, &.{});
    defer exc_hit.deinit();
    try testing.expectEqualStrings("EXC", exc_hit.before);
    var exc_miss = try activate(testing.allocator, .{ .entries = &two, .chara_filename = "alice.png" }, &.{});
    defer exc_miss.deinit();
    try testing.expectEqualStrings("", exc_miss.before);
}

test "characterFilter by tag applies only when the character has a tag mapping" {
    var e = te(0, &.{}, "T");
    e.constant = true;
    e.char_filter_tags = &.{"tag-red"};
    const entries = [_]Entry{e};
    // Include mode, the character carries the tag: fires.
    var hit = try activate(testing.allocator, .{ .entries = &entries, .char_tags = &.{ "tag-red", "tag-blue" } }, &.{});
    defer hit.deinit();
    try testing.expectEqualStrings("T", hit.before);
    // Mapping present but without the tag: filtered out.
    var miss = try activate(testing.allocator, .{ .entries = &entries, .char_tags = &.{"tag-blue"} }, &.{});
    defer miss.deinit();
    try testing.expectEqualStrings("", miss.before);
    // Mapping present but EMPTY: an include filter still rejects it.
    var empty = try activate(testing.allocator, .{ .entries = &entries, .char_tags = &[_][]const u8{} }, &.{});
    defer empty.deinit();
    try testing.expectEqualStrings("", empty.before);
    // NULL char_tags (no mapping at all): stock skips the tag filter, so it fires.
    var no_map = try activate(testing.allocator, .{ .entries = &entries, .char_tags = null }, &.{});
    defer no_map.deinit();
    try testing.expectEqualStrings("T", no_map.before);
}

test "generation-type triggers gate an entry to the listed types" {
    var e = te(0, &.{}, "TRIG");
    e.constant = true;
    e.triggers = &.{ "swipe", "regenerate" };
    const entries = [_]Entry{e};
    var hit = try activate(testing.allocator, .{ .entries = &entries, .generation_trigger = "swipe" }, &.{});
    defer hit.deinit();
    try testing.expectEqualStrings("TRIG", hit.before);
    var miss = try activate(testing.allocator, .{ .entries = &entries, .generation_trigger = "normal" }, &.{});
    defer miss.deinit();
    try testing.expectEqualStrings("", miss.before);
    // An empty triggers list fires for every generation type.
    var any = te(1, &.{}, "ANY");
    any.constant = true;
    const two = [_]Entry{any};
    var a2 = try activate(testing.allocator, .{ .entries = &two, .generation_trigger = "impersonate" }, &.{});
    defer a2.deinit();
    try testing.expectEqualStrings("ANY", a2.before);
}

test "an extended scan source activates an entry only when its match flag is on and the text is present" {
    var e = te(0, &.{"secret"}, "X");
    e.match_persona_description = true;
    const entries = [_]Entry{e};
    // The key is absent from chat but present in the persona description; the flag lets it match.
    var on = try activate(testing.allocator, .{ .entries = &entries, .persona_description = "a secret persona" }, &.{"unrelated"});
    defer on.deinit();
    try testing.expectEqualStrings("X", on.before);
    // Same source text, flag OFF: no match.
    const off_entries = [_]Entry{te(1, &.{"secret"}, "Y")};
    var off = try activate(testing.allocator, .{ .entries = &off_entries, .persona_description = "a secret persona" }, &.{"unrelated"});
    defer off.deinit();
    try testing.expectEqualStrings("", off.before);
    // Flag on but the source text empty: no match.
    var empty_src = try activate(testing.allocator, .{ .entries = &entries, .persona_description = "" }, &.{"unrelated"});
    defer empty_src.deinit();
    try testing.expectEqualStrings("", empty_src.before);
}

test "a decorated sticky entry keeps a stable timed hash across sends" {
    // An unknown @@decorator is stripped but does NOT force activation, so send 2 can only re-fire
    // through the sticky effect, whose key hash must match the send-1 seed over the SAME stripped content.
    var e = tt(0, &.{"dragon"}, "@@note\nBODY", "w");
    e.sticky = 2;
    const entries = [_]Entry{e};
    var s1 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1 }, &.{"a dragon"});
    defer s1.deinit();
    try testing.expectEqualStrings("BODY", s1.before);
    try testing.expectEqual(@as(usize, 1), s1.timed_out.sticky.len);
    var s2 = try activate(testing.allocator, .{ .entries = &entries, .scan_depth = 1, .timed_in = s1.timed_out }, &.{ "a dragon", "boring" });
    defer s2.deinit();
    try testing.expectEqualStrings("BODY", s2.before);
}

test "chunk-4 features clean up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var deco = te(0, &.{"secret"}, "@@activate\nFORCED");
            deco.char_filter_names = &.{"alice.png"};
            var scan = te(1, &.{"secret"}, "SCAN");
            scan.match_persona_description = true;
            scan.match_scenario = true;
            scan.group = "g";
            scan.use_group_scoring = true;
            var tagged = te(2, &.{"secret"}, "TAG");
            tagged.char_filter_tags = &.{"tag-red"};
            tagged.group = "g";
            tagged.use_group_scoring = true;
            const entries = [_]Entry{ deco, scan, tagged };
            var prng = std.Random.DefaultPrng.init(0x4242);
            var act = try activate(alloc, .{
                .entries = &entries,
                .chara_filename = "alice.png",
                .char_tags = &.{"tag-red"},
                .generation_trigger = "normal",
                .persona_description = "a secret persona",
                .scenario = "the secret scenario",
                .use_group_scoring = true,
                .rng = prng.random(),
            }, &.{"a secret"});
            act.deinit();
        }
    }.run, .{});
}
