//! World-info store: the loaded lorebooks, the three scope links (global select, character, chat)
//! and the WI budget knob. (w3-wi)
//!
//! A book is held as the PARSED whole-file JSON in its own arena; the typed `Entry` views expose
//! the MUST-tier fields and every edit writes through to the underlying JSON value. Saving
//! stringifies the root, so fields this client does not model (recursion flags, group scoring,
//! stock fields added tomorrow) survive an edit round-trip by construction - the T0 guarantee.
//! Memory is STORE-OWNED (probe 3 delta): books never ride the per-send stash.
//!
//! Pure Zig (no zx), proven natively in `zig build test`; world_info_actions.zig owns the network
//! and panel glue.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.wi);

/// world_info_logic in the stock client: how secondary keys gate a primary-key hit.
pub const Logic = enum(i64) { and_any = 0, not_all = 1, not_any = 2, and_all = 3 };

/// world_info_position: where an activated entry inserts. at_depth carries the `depth` field.
pub const Position = enum(i64) { before = 0, after = 1, an_top = 2, an_bottom = 3, at_depth = 4, em_top = 5, em_bottom = 6, outlet = 7 };

/// Typed view of one entry's MUST-tier fields. Slices point into the owning book's arena; the
/// engine consumes this as-is. `uid_key` is the entry's key in the file's `entries` object.
pub const Entry = struct {
    uid_key: []const u8,
    uid: i64,
    /// Source book identity (file_id), tagged by collectActive. Feeds the timed-effect key
    /// "<world>.<uid>" so a sticky/cooldown effect survives across sends. Empty for the embedded
    /// character book (at most one per chat, so its ".<uid>" keys stay unique).
    world: []const u8 = "",
    keys: []const []const u8,
    keysecondary: []const []const u8,
    selective_logic: Logic,
    content: []const u8,
    comment: []const u8,
    constant: bool,
    selective: bool,
    disable: bool,
    order: i64,
    position: Position,
    depth: i64,
    probability: i64,
    use_probability: bool,
    /// Stock outletName: which {{outlet::name}} macro an outlet-position entry feeds. Empty = none;
    /// stock skips such an entry (world-info.js:5128) and the engine mirrors that.
    outlet_name: []const u8,
    /// null falls back to the store global (world_info_case_sensitive), stock `?? world_info_...`.
    case_sensitive: ?bool = null,
    /// null falls back to world_info_match_whole_words.
    match_whole_words: ?bool = null,
    /// null falls back to world_info_depth (the store scan_depth).
    scan_depth: ?i64 = null,
    /// atDepth role: 0 system, 1 user, 2 assistant (stock extension_prompt_roles).
    role: i64 = 0,
    /// Stock ignoreBudget: the entry activates even past the WI budget cap.
    ignore_budget: bool = false,
    /// Stock excludeRecursion: the entry's content never re-enters the recursive scan.
    exclude_recursion: bool = false,
    /// Stock preventRecursion: the entry never activates FROM a recursive pass (only the first scan).
    prevent_recursion: bool = false,
    /// Stock delayUntilRecursion: the entry cannot activate until at least this recursion level
    /// (1 = any recursion pass; higher = deeper). 0 = no delay.
    delay_until_recursion: i64 = 0,
    /// Stock group: comma-separated inclusion-group names; an entry may belong to several groups.
    group: []const u8 = "",
    /// Stock groupOverride: this entry wins its inclusion group outright (highest-order prio winner).
    group_override: bool = false,
    /// Stock groupWeight: weight in the group's weighted-random pick (stock DEFAULT_WEIGHT = 100).
    group_weight: i64 = 100,
    /// null falls back to the store global (world_info_use_group_scoring).
    use_group_scoring: ?bool = null,
    /// Stock sticky: once activated, the entry stays active for this many further messages. 0 = off.
    sticky: i64 = 0,
    /// Stock cooldown: after activating, the entry is suppressed for this many messages. 0 = off.
    cooldown: i64 = 0,
    /// Stock delay: the entry cannot activate until the chat has at least this many messages. 0 = off.
    delay: i64 = 0,
};

/// One row of POST /api/worldinfo/list.
pub const BookMeta = struct {
    file_id: []const u8,
    name: []const u8,
};

/// String entry fields the editor writes. Tag names are the exact JSON keys.
pub const StrField = enum { content, comment, outletName };
/// Numeric entry fields. Tag names are the exact JSON keys.
pub const NumField = enum { order, depth, probability, position, selectiveLogic };
/// Boolean entry fields. Tag names are the exact JSON keys.
pub const BoolField = enum { constant, selective, disable, useProbability };
/// The two keyword arrays. Tag names are the exact JSON keys.
pub const KeyField = enum { key, keysecondary };

/// The stock newWorldInfoEntryTemplate (world-info.js:4000), so an entry created here carries the
/// full stock field set, not just the modeled subset.
const new_entry_template =
    \\{"key":[],"keysecondary":[],"comment":"","content":"","constant":false,"vectorized":false,
    \\"selective":true,"selectiveLogic":0,"addMemo":false,"order":100,"position":0,"disable":false,
    \\"ignoreBudget":false,"excludeRecursion":false,"preventRecursion":false,
    \\"matchPersonaDescription":false,"matchCharacterDescription":false,
    \\"matchCharacterPersonality":false,"matchCharacterDepthPrompt":false,"matchScenario":false,
    \\"matchCreatorNotes":false,"delayUntilRecursion":0,"probability":100,"useProbability":true,
    \\"depth":4,"outletName":"","group":"","groupOverride":false,"groupWeight":100,
    \\"scanDepth":null,"caseSensitive":null,"matchWholeWords":null,"useGroupScoring":null,
    \\"automationId":"","role":0,"sticky":null,"cooldown":null,"delay":null,"triggers":[]}
;

/// A whole lorebook: the parsed file JSON plus the typed entry views over it.
pub const Book = struct {
    arena: std.heap.ArenaAllocator,
    /// Server file name (save target). Empty for the embedded character book.
    file_id: []const u8,
    root: std.json.Value,
    entries: []Entry,
    dirty: bool = false,
    /// The embedded character book edits through the card, not /api/worldinfo; view only here.
    read_only: bool = false,

    fn entriesObj(self: *Book) ?*std.json.ObjectMap {
        if (self.root != .object) return null;
        const v = self.root.object.getPtr("entries") orelse return null;
        if (v.* != .object) return null;
        return &v.object;
    }

    fn entryObj(self: *Book, uid_key: []const u8) ?*std.json.ObjectMap {
        const entries = self.entriesObj() orelse return null;
        const v = entries.getPtr(uid_key) orelse return null;
        if (v.* != .object) return null;
        return &v.object;
    }

    pub fn entryByKey(self: *const Book, uid_key: []const u8) ?Entry {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.uid_key, uid_key)) return e;
        }
        return null;
    }
};

// ---- tolerant JSON field reads (files come from disk; never trust shapes) ---------------------

fn getInt(obj: *const std.json.ObjectMap, key: []const u8, default: i64) i64 {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @as(i64, @intFromFloat(f)) else default,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch default,
        .bool => |b| @intFromBool(b),
        else => default,
    };
}

fn getBool(obj: *const std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => default,
    };
}

/// null when the key is absent or JSON null (stock's `entry.field ?? global` default path).
fn getBoolOpt(obj: *const std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => null,
    };
}

fn getIntOpt(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @as(i64, @intFromFloat(f)) else null,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn getStr(obj: *const std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .string => |s| s,
        else => default,
    };
}

fn getStrArray(a: Allocator, obj: *const std.json.ObjectMap, key: []const u8) Allocator.Error![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for (v.array.items) |item| {
        if (item == .string and item.string.len > 0) try out.append(a, item.string);
    }
    return out.toOwnedSlice(a);
}

fn clampNum(field: NumField, v: i64) i64 {
    return switch (field) {
        .order => std.math.clamp(v, 0, 100000),
        .depth => std.math.clamp(v, 0, 10000),
        .probability => std.math.clamp(v, 0, 100),
        .position => std.math.clamp(v, 0, 7),
        .selectiveLogic => std.math.clamp(v, 0, 3),
    };
}

fn entryFromObj(a: Allocator, uid_key: []const u8, obj: *const std.json.ObjectMap) Allocator.Error!Entry {
    return .{
        .uid_key = uid_key,
        .uid = getInt(obj, "uid", std.fmt.parseInt(i64, uid_key, 10) catch 0),
        .keys = try getStrArray(a, obj, "key"),
        .keysecondary = try getStrArray(a, obj, "keysecondary"),
        .selective_logic = @enumFromInt(clampNum(.selectiveLogic, getInt(obj, "selectiveLogic", 0))),
        .content = getStr(obj, "content", ""),
        .comment = getStr(obj, "comment", ""),
        .constant = getBool(obj, "constant", false),
        .selective = getBool(obj, "selective", true),
        .disable = getBool(obj, "disable", false),
        .order = getInt(obj, "order", 100),
        .position = @enumFromInt(clampNum(.position, getInt(obj, "position", 0))),
        .depth = getInt(obj, "depth", 4),
        .probability = clampNum(.probability, getInt(obj, "probability", 100)),
        .use_probability = getBool(obj, "useProbability", true),
        .outlet_name = getStr(obj, "outletName", ""),
        .case_sensitive = getBoolOpt(obj, "caseSensitive"),
        .match_whole_words = getBoolOpt(obj, "matchWholeWords"),
        .scan_depth = getIntOpt(obj, "scanDepth"),
        .role = getInt(obj, "role", 0),
        .ignore_budget = getBool(obj, "ignoreBudget", false),
        .exclude_recursion = getBool(obj, "excludeRecursion", false),
        .prevent_recursion = getBool(obj, "preventRecursion", false),
        .delay_until_recursion = getInt(obj, "delayUntilRecursion", 0),
        .group = getStr(obj, "group", ""),
        .group_override = getBool(obj, "groupOverride", false),
        .group_weight = getInt(obj, "groupWeight", 100),
        .use_group_scoring = getBoolOpt(obj, "useGroupScoring"),
        // Stock stores null|number; getInt folds null/absent to 0 (effect off).
        .sticky = getInt(obj, "sticky", 0),
        .cooldown = getInt(obj, "cooldown", 0),
        .delay = getInt(obj, "delay", 0),
    };
}

// ---- the store --------------------------------------------------------------------------------

pub const WorldInfoStore = struct {
    allocator: Allocator,
    book_list: std.ArrayList(BookMeta) = .empty,
    books: std.ArrayList(Book) = .empty,
    global_selected: std.ArrayList([]const u8) = .empty,
    /// Embedded data.character_book from the selected card, converted from the v2 spec shape.
    char_book: ?Book = null,
    /// Linked book name from the card's data.extensions.world.
    char_world: []const u8 = "",
    /// Book name from the open chat's metadata `world_info` key.
    chat_world: []const u8 = "",
    /// Stock world_info_budget: percent of the prompt budget the WI slice may take (probe 3 delta).
    budget: i64 = 25,
    /// Stock world_info_depth: how many newest messages the engine's key scan reads.
    scan_depth: i64 = 2,
    /// Stock world_info_recursive: activated content re-enters the key scan. Off by default.
    recursive: bool = false,
    /// Stock world_info_case_sensitive: the default an entry's null caseSensitive falls back to.
    case_sensitive: bool = false,
    /// Stock world_info_match_whole_words: default for an entry's null matchWholeWords.
    match_whole_words: bool = false,
    /// Stock world_info_min_activations: if > 0, keep scanning deeper until this many entries fire.
    min_activations: i64 = 0,
    /// Stock world_info_min_activations_depth_max: hard cap on the widened depth (0 = history-bounded).
    min_activations_depth_max: i64 = 0,
    /// Stock world_info_use_group_scoring: default an entry's null useGroupScoring falls back to.
    use_group_scoring: bool = false,
    /// False until the settings blob has hydrated us; mergeState skips until then, or a save fired
    /// before hydration would wipe the account's globalSelect (the persona_actions precedent).
    authoritative: bool = false,

    char_world_owned: ?[]const u8 = null,
    chat_world_owned: ?[]const u8 = null,

    pub fn init(allocator: Allocator) WorldInfoStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WorldInfoStore) void {
        self.clearBookList();
        self.book_list.deinit(self.allocator);
        for (self.books.items) |*b| self.freeBook(b);
        self.books.deinit(self.allocator);
        self.clearGlobalSelected();
        self.global_selected.deinit(self.allocator);
        if (self.char_book) |*b| self.freeBook(b);
        if (self.char_world_owned) |b| self.allocator.free(b);
        if (self.chat_world_owned) |b| self.allocator.free(b);
        self.* = undefined;
    }

    fn freeBook(self: *WorldInfoStore, b: *Book) void {
        self.allocator.free(b.file_id);
        b.arena.deinit();
    }

    fn clearBookList(self: *WorldInfoStore) void {
        for (self.book_list.items) |m| {
            self.allocator.free(m.file_id);
            self.allocator.free(m.name);
        }
        self.book_list.clearRetainingCapacity();
    }

    fn clearGlobalSelected(self: *WorldInfoStore) void {
        for (self.global_selected.items) |s| self.allocator.free(s);
        self.global_selected.clearRetainingCapacity();
    }

    // ---- book list (/list) --------------------------------------------------------------------

    /// Adopt the POST /api/worldinfo/list response. A non-array or a row without file_id is
    /// refused outright rather than half-loaded.
    pub fn setBookListFromJson(self: *WorldInfoStore, bytes: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{});
        if (root != .array) return error.NotAnArray;
        self.clearBookList();
        for (root.array.items) |row| {
            if (row != .object) continue;
            const fid = getStr(&row.object, "file_id", "");
            if (fid.len == 0) continue;
            const name = getStr(&row.object, "name", fid);
            const fid_c = try self.allocator.dupe(u8, fid);
            errdefer self.allocator.free(fid_c);
            const name_c = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_c);
            try self.book_list.append(self.allocator, .{ .file_id = fid_c, .name = name_c });
        }
    }

    pub fn list(self: *const WorldInfoStore) []const BookMeta {
        return self.book_list.items;
    }

    // ---- loading + views ----------------------------------------------------------------------

    /// Adopt a whole book file (POST /api/worldinfo/get body) under `file_id`, replacing any
    /// previously loaded copy. The file must be an object carrying an `entries` object.
    pub fn loadBookFromJson(self: *WorldInfoStore, file_id: []const u8, bytes: []const u8) !void {
        var book = try self.parseBook(file_id, bytes, false);
        errdefer self.freeBook(&book);
        if (self.bookIndex(file_id)) |i| {
            self.freeBook(&self.books.items[i]);
            self.books.items[i] = book;
        } else {
            try self.books.append(self.allocator, book);
        }
    }

    fn parseBook(self: *WorldInfoStore, file_id: []const u8, bytes: []const u8, read_only: bool) !Book {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        // Value parsing dupes every string into the arena (std dynamic.zig alloc_always), so the
        // book never references the response body; the survive-freed-bytes test pins this.
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{});
        if (root != .object) return error.NotABook;
        const entries_v = root.object.get("entries") orelse return error.NotABook;
        if (entries_v != .object) return error.NotABook;
        const fid = try self.allocator.dupe(u8, file_id);
        errdefer self.allocator.free(fid);
        var book: Book = .{ .arena = arena, .file_id = fid, .root = root, .entries = &.{}, .read_only = read_only };
        try rebuildViews(&book);
        return book;
    }

    fn bookIndex(self: *const WorldInfoStore, file_id: []const u8) ?usize {
        for (self.books.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.file_id, file_id)) return i;
        }
        return null;
    }

    pub fn bookByFileId(self: *WorldInfoStore, file_id: []const u8) ?*Book {
        const i = self.bookIndex(file_id) orelse return null;
        return &self.books.items[i];
    }

    pub fn unloadBook(self: *WorldInfoStore, file_id: []const u8) void {
        const i = self.bookIndex(file_id) orelse return;
        self.freeBook(&self.books.items[i]);
        _ = self.books.swapRemove(i);
    }

    fn rebuildViews(book: *Book) Allocator.Error!void {
        const a = book.arena.allocator();
        const entries = book.entriesObj() orelse {
            book.entries = &.{};
            return;
        };
        var out: std.ArrayList(Entry) = .empty;
        errdefer out.deinit(a);
        var it = entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .object) continue;
            try out.append(a, try entryFromObj(a, kv.key_ptr.*, &kv.value_ptr.object));
        }
        book.entries = try out.toOwnedSlice(a);
    }

    // ---- entry mutation (writes through to the JSON, then rebuilds the views) ------------------

    pub fn setEntryStr(self: *WorldInfoStore, book: *Book, uid_key: []const u8, field: StrField, val: []const u8) !void {
        _ = self;
        if (book.read_only) return error.ReadOnly;
        const obj = book.entryObj(uid_key) orelse return error.NoEntry;
        const a = book.arena.allocator();
        try obj.put(a, @tagName(field), .{ .string = try a.dupe(u8, val) });
        try rebuildViews(book);
        book.dirty = true;
    }

    pub fn setEntryNum(self: *WorldInfoStore, book: *Book, uid_key: []const u8, field: NumField, val: i64) !void {
        _ = self;
        if (book.read_only) return error.ReadOnly;
        const obj = book.entryObj(uid_key) orelse return error.NoEntry;
        try obj.put(book.arena.allocator(), @tagName(field), .{ .integer = clampNum(field, val) });
        try rebuildViews(book);
        book.dirty = true;
    }

    pub fn setEntryBool(self: *WorldInfoStore, book: *Book, uid_key: []const u8, field: BoolField, val: bool) !void {
        _ = self;
        if (book.read_only) return error.ReadOnly;
        const obj = book.entryObj(uid_key) orelse return error.NoEntry;
        try obj.put(book.arena.allocator(), @tagName(field), .{ .bool = val });
        try rebuildViews(book);
        book.dirty = true;
    }

    /// Replace a keyword array from the editor's comma-separated text field.
    pub fn setEntryKeys(self: *WorldInfoStore, book: *Book, uid_key: []const u8, field: KeyField, csv: []const u8) !void {
        _ = self;
        if (book.read_only) return error.ReadOnly;
        const obj = book.entryObj(uid_key) orelse return error.NoEntry;
        const a = book.arena.allocator();
        var arr = std.json.Array.init(a);
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |raw| {
            const k = std.mem.trim(u8, raw, " \t\r\n");
            if (k.len == 0) continue;
            try arr.append(.{ .string = try a.dupe(u8, k) });
        }
        try obj.put(a, @tagName(field), .{ .array = arr });
        try rebuildViews(book);
        book.dirty = true;
    }

    /// Comma-joined keyword list for the editor's text field. Allocated in `a` (render arena).
    pub fn keysCsv(a: Allocator, keys: []const []const u8) []const u8 {
        return std.mem.join(a, ", ", keys) catch "";
    }

    /// Create an entry from the full stock template, keyed max-uid+1. Returns the new uid.
    pub fn createEntry(self: *WorldInfoStore, book: *Book) !i64 {
        _ = self;
        if (book.read_only) return error.ReadOnly;
        const a = book.arena.allocator();
        const entries = book.entriesObj() orelse return error.NotABook;
        var max: i64 = -1;
        for (book.entries) |e| max = @max(max, e.uid);
        const uid = max + 1;
        const tmpl = try std.json.parseFromSliceLeaky(std.json.Value, a, new_entry_template, .{});
        var obj = tmpl.object;
        try obj.put(a, "uid", .{ .integer = uid });
        try obj.put(a, "displayIndex", .{ .integer = uid });
        const key = try std.fmt.allocPrint(a, "{d}", .{uid});
        try entries.put(a, key, .{ .object = obj });
        try rebuildViews(book);
        book.dirty = true;
        return uid;
    }

    pub fn deleteEntry(self: *WorldInfoStore, book: *Book, uid_key: []const u8) !void {
        _ = self;
        if (book.read_only) return error.ReadOnly;
        const entries = book.entriesObj() orelse return error.NotABook;
        if (!entries.orderedRemove(uid_key)) return error.NoEntry;
        try rebuildViews(book);
        book.dirty = true;
    }

    /// The POST /api/worldinfo/edit body for `book`: {name, data} with data = the whole parsed
    /// file, so every unmodeled field rides along. Caller frees.
    pub fn serializeForEdit(self: *WorldInfoStore, book: *const Book) ![]u8 {
        if (book.read_only) return error.ReadOnly;
        return std.json.Stringify.valueAlloc(self.allocator, .{ .name = book.file_id, .data = book.root }, .{});
    }

    // ---- the embedded character book (v2 spec -> WI shape, view only) --------------------------

    /// Adopt the card's data.character_book (v2 spec: entries is an ARRAY with its own field
    /// names). Converted to the WI shape so the panel and the engine read one model; view only.
    pub fn loadCharBookFromJson(self: *WorldInfoStore, bytes: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
        if (root != .object) return error.NotABook;
        const src = root.object.get("entries") orelse return error.NotABook;
        if (src != .array) return error.NotABook;

        var entries: std.json.ObjectMap = .empty;
        for (src.array.items, 0..) |row, i| {
            if (row != .object) continue;
            const conv = try convertV2Entry(a, &row.object, @intCast(i));
            const key = try std.fmt.allocPrint(a, "{d}", .{i});
            try entries.put(a, key, .{ .object = conv });
        }
        var out: std.json.ObjectMap = .empty;
        try out.put(a, "name", .{ .string = getStr(&root.object, "name", "Character Lorebook") });
        try out.put(a, "entries", .{ .object = entries });

        if (self.char_book) |*old| self.freeBook(old);
        var book: Book = .{ .arena = arena, .file_id = try self.allocator.dupe(u8, ""), .root = .{ .object = out }, .entries = &.{}, .read_only = true };
        try rebuildViews(&book);
        self.char_book = book;
    }

    pub fn clearCharBook(self: *WorldInfoStore) void {
        if (self.char_book) |*old| self.freeBook(old);
        self.char_book = null;
    }

    /// Adopt the selected card's world-info surface from the raw /api/characters/get body: the
    /// linked book name (data.extensions.world) and the embedded book (data.character_book). Both
    /// are cleared first, so a card carrying neither leaves no stale link from the previous card.
    pub fn adoptCharCard(self: *WorldInfoStore, bytes: []const u8) void {
        self.setCharWorld("");
        self.clearCharBook();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{}) catch {
            log.warn("char card unparseable, world-info links skipped", .{});
            return;
        };
        if (root != .object) return;
        const d = root.object.get("data") orelse return;
        if (d != .object) return;
        if (d.object.get("extensions")) |ext| {
            if (ext == .object) self.setCharWorld(getStr(&ext.object, "world", ""));
        }
        const cb = d.object.get("character_book") orelse return;
        if (cb != .object) return;
        const book_bytes = std.json.Stringify.valueAlloc(self.allocator, cb, .{}) catch return;
        defer self.allocator.free(book_bytes);
        self.loadCharBookFromJson(book_bytes) catch |err| {
            log.warn("embedded character book rejected: {s}", .{@errorName(err)});
        };
    }

    // ---- scope links ---------------------------------------------------------------------------

    pub fn setCharWorld(self: *WorldInfoStore, name: []const u8) void {
        if (self.char_world_owned) |b| self.allocator.free(b);
        self.char_world_owned = null;
        self.char_world = "";
        if (name.len == 0) return;
        const c = self.allocator.dupe(u8, name) catch return;
        self.char_world = c;
        self.char_world_owned = c;
    }

    pub fn setChatWorld(self: *WorldInfoStore, name: []const u8) void {
        if (self.chat_world_owned) |b| self.allocator.free(b);
        self.chat_world_owned = null;
        self.chat_world = "";
        if (name.len == 0) return;
        const c = self.allocator.dupe(u8, name) catch return;
        self.chat_world = c;
        self.chat_world_owned = c;
    }

    pub fn isGlobalSelected(self: *const WorldInfoStore, file_id: []const u8) bool {
        for (self.global_selected.items) |s| {
            if (std.mem.eql(u8, s, file_id)) return true;
        }
        return false;
    }

    /// Add or remove a book from the global selection. Returns the new membership.
    pub fn toggleGlobal(self: *WorldInfoStore, file_id: []const u8) !bool {
        for (self.global_selected.items, 0..) |s, i| {
            if (std.mem.eql(u8, s, file_id)) {
                self.allocator.free(s);
                _ = self.global_selected.orderedRemove(i);
                return false;
            }
        }
        const c = try self.allocator.dupe(u8, file_id);
        errdefer self.allocator.free(c);
        try self.global_selected.append(self.allocator, c);
        return true;
    }

    pub fn setBudget(self: *WorldInfoStore, v: i64) void {
        self.budget = std.math.clamp(v, 1, 100);
    }

    // ---- the settings blob (classic-client keys, one shared saver) -----------------------------

    /// Adopt globalSelect + world_info_budget from the account settings blob. Stock nests them
    /// under `world_info_settings` (script.js:8057) and falls back to the root on old blobs.
    pub fn setFromSettings(self: *WorldInfoStore, settings_str: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), settings_str, .{}) catch return;
        if (root != .object) return;
        self.authoritative = true;
        const ws: *const std.json.ObjectMap = blk: {
            if (root.object.getPtr("world_info_settings")) |v| {
                if (v.* == .object) break :blk &v.object;
            }
            break :blk &root.object;
        };
        self.budget = std.math.clamp(getInt(ws, "world_info_budget", self.budget), 1, 100);
        // 1000 = stock MAX_SCAN_DEPTH (world-info.js).
        self.scan_depth = std.math.clamp(getInt(ws, "world_info_depth", self.scan_depth), 0, 1000);
        self.recursive = getBool(ws, "world_info_recursive", self.recursive);
        self.case_sensitive = getBool(ws, "world_info_case_sensitive", self.case_sensitive);
        self.match_whole_words = getBool(ws, "world_info_match_whole_words", self.match_whole_words);
        self.min_activations = std.math.clamp(getInt(ws, "world_info_min_activations", self.min_activations), 0, 1000);
        self.min_activations_depth_max = std.math.clamp(getInt(ws, "world_info_min_activations_depth_max", self.min_activations_depth_max), 0, 1000);
        self.use_group_scoring = getBool(ws, "world_info_use_group_scoring", self.use_group_scoring);
        const wi = ws.get("world_info") orelse return;
        if (wi != .object) return;
        const sel = wi.object.get("globalSelect") orelse return;
        if (sel != .array) return;
        self.clearGlobalSelected();
        for (sel.array.items) |item| {
            if (item != .string or item.string.len == 0) continue;
            const c = self.allocator.dupe(u8, item.string) catch continue;
            self.global_selected.append(self.allocator, c) catch {
                self.allocator.free(c);
                return;
            };
        }
    }

    /// Write globalSelect + world_info_budget into the settings blob being saved, preserving every
    /// other key inside world_info_settings (depth, recursion toggles - the classic client's).
    /// A no-op until hydration (authoritative), so an early unrelated save cannot wipe the account.
    pub fn mergeState(self: *const WorldInfoStore, a: Allocator, root_obj: *std.json.ObjectMap) !void {
        if (!self.authoritative) return;
        var ws: std.json.ObjectMap = blk: {
            if (root_obj.get("world_info_settings")) |v| {
                if (v == .object) break :blk v.object;
            }
            break :blk .empty;
        };
        var wi: std.json.ObjectMap = blk: {
            if (ws.get("world_info")) |v| {
                if (v == .object) break :blk v.object;
            }
            break :blk .empty;
        };
        var sel = std.json.Array.init(a);
        for (self.global_selected.items) |s| {
            try sel.append(.{ .string = try a.dupe(u8, s) });
        }
        try wi.put(a, "globalSelect", .{ .array = sel });
        try ws.put(a, "world_info", .{ .object = wi });
        try ws.put(a, "world_info_budget", .{ .integer = self.budget });
        try ws.put(a, "world_info_depth", .{ .integer = self.scan_depth });
        try ws.put(a, "world_info_recursive", .{ .bool = self.recursive });
        try root_obj.put(a, "world_info_settings", .{ .object = ws });
    }

    // ---- engine candidates (w3-wi-engine) ------------------------------------------------------

    /// A scope link resolved to a LOADED book. The link value is this client's file_id, or a stock
    /// client's display name; both resolve, name via the /list rows.
    pub fn resolveBookRef(self: *WorldInfoStore, ref: []const u8) ?*Book {
        if (ref.len == 0) return null;
        if (self.bookByFileId(ref)) |b| return b;
        for (self.book_list.items) |m| {
            if (std.mem.eql(u8, m.name, ref)) return self.bookByFileId(m.file_id);
        }
        return null;
    }

    /// The file_id a scope link should be fetched under (the link itself, or the /list row whose
    /// display name matches). Null only for an empty link.
    pub fn resolveRefFileId(self: *const WorldInfoStore, ref: []const u8) ?[]const u8 {
        if (ref.len == 0) return null;
        for (self.book_list.items) |m| {
            if (std.mem.eql(u8, m.file_id, ref)) return m.file_id;
        }
        for (self.book_list.items) |m| {
            if (std.mem.eql(u8, m.name, ref)) return m.file_id;
        }
        return ref;
    }

    /// Engine candidates in stock priority order: chat lore, then character lore (embedded book +
    /// the card's linked world), then the global selection, each book's entries by order DESCENDING
    /// (sortFn world-info.js:89 under the character_first default strategy). A book reachable
    /// through two scopes contributes once. Entry views borrow the store's book arenas; only the
    /// returned slice is caller-owned.
    pub fn collectActive(self: *WorldInfoStore, a: Allocator) Allocator.Error![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        errdefer out.deinit(a);
        var seen: std.ArrayList(*const Book) = .empty;
        defer seen.deinit(a);

        if (self.resolveBookRef(self.chat_world)) |b| try appendBookSorted(&out, &seen, a, b);
        // Stock getCharacterLore activates the LINKED world (data.extensions.world), not the embedded
        // character_book (import extracts the book INTO that world); using both double-counts every entry.
        if (self.resolveBookRef(self.char_world)) |b| {
            try appendBookSorted(&out, &seen, a, b);
        } else if (self.char_book) |*cb| {
            try appendBookSorted(&out, &seen, a, cb);
        }
        for (self.global_selected.items) |fid| {
            if (self.bookByFileId(fid)) |b| try appendBookSorted(&out, &seen, a, b);
        }
        return out.toOwnedSlice(a);
    }
};

fn appendBookSorted(out: *std.ArrayList(Entry), seen: *std.ArrayList(*const Book), a: Allocator, book: *const Book) Allocator.Error!void {
    for (seen.items) |s| {
        if (s == book) return;
    }
    try seen.append(a, book);
    const start = out.items.len;
    try out.appendSlice(a, book.entries);
    // Tag the timed-effect world identity from the source book; borrows the store-owned file_id.
    for (out.items[start..]) |*e| e.world = book.file_id;
    std.mem.sort(Entry, out.items[start..], {}, orderDesc);
}

fn orderDesc(_: void, lhs: Entry, rhs: Entry) bool {
    if (lhs.order != rhs.order) return lhs.order > rhs.order;
    return lhs.uid < rhs.uid;
}

/// One v2-spec entry to the WI shape (stock convertCharacterBook): extensions win, then the v2
/// field, then the stock default. Unconverted extension keys are carried verbatim.
fn convertV2Entry(a: Allocator, src: *const std.json.ObjectMap, index: i64) Allocator.Error!std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    const ext: ?*const std.json.ObjectMap = blk: {
        const v = src.get("extensions") orelse break :blk null;
        if (v != .object) break :blk null;
        break :blk &v.object;
    };
    if (ext) |e| {
        var it = e.iterator();
        while (it.next()) |kv| try out.put(a, kv.key_ptr.*, kv.value_ptr.*);
    }
    try out.put(a, "uid", .{ .integer = index });
    if (src.get("keys")) |v| try out.put(a, "key", v) else try out.put(a, "key", .{ .array = std.json.Array.init(a) });
    if (src.get("secondary_keys")) |v| try out.put(a, "keysecondary", v) else try out.put(a, "keysecondary", .{ .array = std.json.Array.init(a) });
    try out.put(a, "comment", .{ .string = getStr(src, "comment", "") });
    try out.put(a, "content", .{ .string = getStr(src, "content", "") });
    try out.put(a, "constant", .{ .bool = getBool(src, "constant", false) });
    try out.put(a, "selective", .{ .bool = getBool(src, "selective", false) });
    try out.put(a, "disable", .{ .bool = !getBool(src, "enabled", true) });
    const order = if (ext) |e| getInt(e, "insertion_order", getInt(src, "insertion_order", 100)) else getInt(src, "insertion_order", 100);
    try out.put(a, "order", .{ .integer = order });
    const pos: i64 = blk: {
        if (ext) |e| {
            if (e.get("position") != null) break :blk clampNum(.position, getInt(e, "position", 0));
        }
        break :blk if (std.mem.eql(u8, getStr(src, "position", ""), "after_char")) 1 else 0;
    };
    try out.put(a, "position", .{ .integer = pos });
    const exti = struct {
        fn get(e: ?*const std.json.ObjectMap, key: []const u8, default: i64) i64 {
            return if (e) |m| getInt(m, key, default) else default;
        }
        fn getB(e: ?*const std.json.ObjectMap, key: []const u8, default: bool) bool {
            return if (e) |m| getBool(m, key, default) else default;
        }
    };
    try out.put(a, "selectiveLogic", .{ .integer = clampNum(.selectiveLogic, exti.get(ext, "selectiveLogic", 0)) });
    try out.put(a, "probability", .{ .integer = clampNum(.probability, exti.get(ext, "probability", 100)) });
    try out.put(a, "useProbability", .{ .bool = exti.getB(ext, "useProbability", true) });
    try out.put(a, "depth", .{ .integer = exti.get(ext, "depth", 4) });
    return out;
}

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const page_gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;

pub var global: WorldInfoStore = .{ .allocator = page_gpa };

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;

const fixture_book =
    \\{"name":"Test Lore","entries":{
    \\"0":{"uid":0,"key":["dragon","wyrm"],"keysecondary":["red"],"comment":"the dragon","content":"Dragons breathe fire.","constant":false,"vectorized":false,"selective":true,"selectiveLogic":1,"addMemo":true,"order":90,"position":4,"disable":false,"ignoreBudget":false,"excludeRecursion":true,"preventRecursion":false,"matchPersonaDescription":false,"matchCharacterDescription":false,"matchCharacterPersonality":false,"matchCharacterDepthPrompt":false,"matchScenario":false,"matchCreatorNotes":false,"delayUntilRecursion":0,"probability":75,"useProbability":true,"depth":6,"outletName":"beast-notes","group":"beasts","groupOverride":false,"groupWeight":100,"scanDepth":null,"caseSensitive":null,"matchWholeWords":null,"useGroupScoring":null,"automationId":"","role":0,"sticky":2,"cooldown":0,"delay":0,"displayIndex":0,"triggers":[],"futureField":{"nested":[1,2,3]}},
    \\"3":{"uid":3,"key":["castle"],"keysecondary":[],"comment":"","content":"The castle stands.","constant":true,"selective":false,"selectiveLogic":0,"order":100,"position":0,"disable":true,"probability":100,"useProbability":false,"depth":4}
    \\},"extensions":{"custom":"kept"}}
;

fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a) != @as(std.meta.Tag(std.json.Value), b)) {
        const an: ?f64 = switch (a) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
        const bn: ?f64 = switch (b) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
        if (an != null and bn != null) return an.? == bn.?;
        return false;
    }
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len) break :blk false;
            for (v.items, b.array.items) |x, y| {
                if (!jsonEql(x, y)) break :blk false;
            }
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |kv| {
                const other = b.object.get(kv.key_ptr.*) orelse break :blk false;
                if (!jsonEql(kv.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

test "load parses the MUST fields of a stock book" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.loadBookFromJson("test-lore", fixture_book);
    const b = s.bookByFileId("test-lore").?;
    try testing.expectEqual(@as(usize, 2), b.entries.len);
    const e = b.entryByKey("0").?;
    try testing.expectEqual(@as(usize, 2), e.keys.len);
    try testing.expectEqualStrings("dragon", e.keys[0]);
    try testing.expectEqualStrings("red", e.keysecondary[0]);
    try testing.expectEqual(Logic.not_all, e.selective_logic);
    try testing.expectEqualStrings("Dragons breathe fire.", e.content);
    try testing.expectEqual(Position.at_depth, e.position);
    try testing.expectEqual(@as(i64, 6), e.depth);
    try testing.expectEqual(@as(i64, 75), e.probability);
    try testing.expectEqual(@as(i64, 90), e.order);
    try testing.expect(e.selective and e.use_probability and !e.constant and !e.disable);
    try testing.expectEqualStrings("beast-notes", e.outlet_name);
    const c = b.entryByKey("3").?;
    try testing.expect(c.constant and c.disable and !c.use_probability);
}

test "editing one field round-trips every unmodeled field intact" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.loadBookFromJson("test-lore", fixture_book);
    const b = s.bookByFileId("test-lore").?;
    try s.setEntryStr(b, "0", .content, "Dragons hoard gold.");
    try testing.expect(b.dirty);
    const body = try s.serializeForEdit(b);
    defer testing.allocator.free(body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const before = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), fixture_book, .{});
    const sent = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    try testing.expectEqualStrings("test-lore", sent.object.get("name").?.string);
    const after = sent.object.get("data").?;

    try testing.expect(jsonEql(after.object.get("extensions").?, before.object.get("extensions").?));
    const e_before = before.object.get("entries").?.object.get("0").?.object;
    const e_after = after.object.get("entries").?.object.get("0").?.object;
    try testing.expectEqual(e_before.count(), e_after.count());
    var it = e_before.iterator();
    while (it.next()) |kv| {
        const other = e_after.get(kv.key_ptr.*).?;
        if (std.mem.eql(u8, kv.key_ptr.*, "content")) {
            try testing.expectEqualStrings("Dragons hoard gold.", other.string);
        } else {
            try testing.expect(jsonEql(kv.value_ptr.*, other));
        }
    }
    try testing.expect(jsonEql(after.object.get("entries").?.object.get("3").?, before.object.get("entries").?.object.get("3").?));
}

test "created entry carries the full stock template and a fresh uid" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.loadBookFromJson("test-lore", fixture_book);
    const b = s.bookByFileId("test-lore").?;
    const uid = try s.createEntry(b);
    try testing.expectEqual(@as(i64, 4), uid);
    const e = b.entryByKey("4").?;
    try testing.expectEqual(@as(i64, 100), e.order);
    try testing.expectEqual(@as(i64, 100), e.probability);
    const obj = b.entryObj("4").?;
    try testing.expect(obj.get("excludeRecursion") != null);
    try testing.expect(obj.get("groupWeight") != null);
    try testing.expect(obj.get("triggers") != null);
    try testing.expectEqual(@as(usize, 41), obj.count());
}

test "delete removes only the named entry" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.loadBookFromJson("test-lore", fixture_book);
    const b = s.bookByFileId("test-lore").?;
    try s.deleteEntry(b, "0");
    try testing.expectEqual(@as(usize, 1), b.entries.len);
    try testing.expect(b.entryByKey("3") != null);
    try testing.expectError(error.NoEntry, s.deleteEntry(b, "0"));
}

test "keys csv splits, trims and drops empties both ways" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.loadBookFromJson("test-lore", fixture_book);
    const b = s.bookByFileId("test-lore").?;
    try s.setEntryKeys(b, "3", .key, " sword,  shield ,,axe ");
    const e = b.entryByKey("3").?;
    try testing.expectEqual(@as(usize, 3), e.keys.len);
    try testing.expectEqualStrings("shield", e.keys[1]);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("sword, shield, axe", WorldInfoStore.keysCsv(arena.allocator(), e.keys));
}

test "numeric edits clamp to their stock ranges" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.loadBookFromJson("test-lore", fixture_book);
    const b = s.bookByFileId("test-lore").?;
    try s.setEntryNum(b, "3", .probability, 150);
    try testing.expectEqual(@as(i64, 100), b.entryByKey("3").?.probability);
    try s.setEntryNum(b, "3", .position, 99);
    try testing.expectEqual(Position.outlet, b.entryByKey("3").?.position);
    try s.setEntryNum(b, "3", .selectiveLogic, -5);
    try testing.expectEqual(Logic.and_any, b.entryByKey("3").?.selective_logic);
}

test "garbage and shapeless files are refused, not half-loaded" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try testing.expectError(error.SyntaxError, s.loadBookFromJson("x", "not json"));
    try testing.expectError(error.NotABook, s.loadBookFromJson("x", "[1,2]"));
    try testing.expectError(error.NotABook, s.loadBookFromJson("x", "{\"name\":\"no entries\"}"));
    try testing.expect(s.bookByFileId("x") == null);
}

test "book list adopts rows and skips malformed ones" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.setBookListFromJson("[{\"file_id\":\"a\",\"name\":\"Alpha\",\"extensions\":{}},{\"name\":\"no id\"},{\"file_id\":\"b\"}]");
    try testing.expectEqual(@as(usize, 2), s.list().len);
    try testing.expectEqualStrings("Alpha", s.list()[0].name);
    try testing.expectEqualStrings("b", s.list()[1].name);
    try testing.expectError(error.NotAnArray, s.setBookListFromJson("{}"));
}

test "settings round-trip: globalSelect and budget load, merge preserves foreign wi keys" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    s.setFromSettings("{\"world_info_settings\":{\"world_info\":{\"globalSelect\":[\"a\",\"b\"]},\"world_info_budget\":40,\"world_info_depth\":2}}");
    try testing.expectEqual(@as(i64, 40), s.budget);
    try testing.expect(s.isGlobalSelected("a") and s.isGlobalSelected("b") and !s.isGlobalSelected("c"));

    try testing.expect(try s.toggleGlobal("c"));
    try testing.expect(!(try s.toggleGlobal("a")));
    s.setBudget(400);
    try testing.expectEqual(@as(i64, 100), s.budget);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = (try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"other\":1,\"world_info_settings\":{\"world_info_depth\":2,\"world_info\":{\"globalSelect\":[\"stale\"]}}}", .{})).object;
    try s.mergeState(a, &root);
    const ws = root.get("world_info_settings").?.object;
    try testing.expectEqual(@as(i64, 2), ws.get("world_info_depth").?.integer);
    try testing.expectEqual(@as(i64, 100), ws.get("world_info_budget").?.integer);
    const sel = ws.get("world_info").?.object.get("globalSelect").?.array;
    try testing.expectEqual(@as(usize, 2), sel.items.len);
    try testing.expectEqualStrings("b", sel.items[0].string);
    try testing.expectEqualStrings("c", sel.items[1].string);
    try testing.expectEqual(@as(i64, 1), root.get("other").?.integer);

    var cold = WorldInfoStore.init(testing.allocator);
    defer cold.deinit();
    try cold.mergeState(a, &root);
    const sel2 = root.get("world_info_settings").?.object.get("world_info").?.object.get("globalSelect").?.array;
    try testing.expectEqual(@as(usize, 2), sel2.items.len);
}

const fixture_v2_book =
    \\{"name":"Card Book","entries":[
    \\{"keys":["home"],"secondary_keys":["town"],"content":"Home base.","enabled":true,"insertion_order":50,"position":"after_char","extensions":{"probability":60,"depth":9,"custom_ext":true}},
    \\{"keys":["foe"],"content":"The rival.","enabled":false,"position":"before_char"}
    \\]}
;

test "v2 character book converts to the wi shape read-only" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.loadCharBookFromJson(fixture_v2_book);
    const b = &s.char_book.?;
    try testing.expectEqual(@as(usize, 2), b.entries.len);
    const e0 = b.entryByKey("0").?;
    try testing.expectEqualStrings("home", e0.keys[0]);
    try testing.expectEqualStrings("town", e0.keysecondary[0]);
    try testing.expectEqual(Position.after, e0.position);
    try testing.expectEqual(@as(i64, 60), e0.probability);
    try testing.expectEqual(@as(i64, 9), e0.depth);
    try testing.expectEqual(@as(i64, 50), e0.order);
    const e1 = b.entryByKey("1").?;
    try testing.expect(e1.disable);
    try testing.expectEqual(Position.before, e1.position);
    try testing.expectError(error.ReadOnly, s.setEntryStr(b, "0", .content, "nope"));
    try testing.expectError(error.ReadOnly, s.serializeForEdit(b));
    s.clearCharBook();
    try testing.expect(s.char_book == null);
}

test "scope names are store-owned copies" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..5], "lorea");
    s.setCharWorld(buf[0..5]);
    s.setChatWorld(buf[0..5]);
    @memcpy(buf[0..5], "XXXXX");
    try testing.expectEqualStrings("lorea", s.char_world);
    try testing.expectEqualStrings("lorea", s.chat_world);
    s.setCharWorld("");
    try testing.expectEqualStrings("", s.char_world);
}

test "book strings survive the source bytes being freed" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    const heap_book = try testing.allocator.dupe(u8, fixture_book);
    try s.loadBookFromJson("test-lore", heap_book);
    testing.allocator.free(heap_book);
    const heap_v2 = try testing.allocator.dupe(u8, fixture_v2_book);
    try s.loadCharBookFromJson(heap_v2);
    testing.allocator.free(heap_v2);
    try testing.expectEqualStrings("Dragons breathe fire.", s.bookByFileId("test-lore").?.entryByKey("0").?.content);
    try testing.expectEqualStrings("Home base.", s.char_book.?.entryByKey("0").?.content);
}

test "char card adoption links the world and the embedded book, and clears both without them" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    const card = try std.fmt.allocPrint(testing.allocator,
        \\{{"name":"Alice","data":{{"extensions":{{"world":"alice-lore","depth_prompt":{{}}}},"character_book":{s}}}}}
    , .{fixture_v2_book});
    defer testing.allocator.free(card);
    s.adoptCharCard(card);
    try testing.expectEqualStrings("alice-lore", s.char_world);
    try testing.expectEqual(@as(usize, 2), s.char_book.?.entries.len);
    try testing.expectEqualStrings("home", s.char_book.?.entryByKey("0").?.keys[0]);

    s.adoptCharCard("{\"name\":\"Bob\",\"data\":{\"extensions\":{}}}");
    try testing.expectEqualStrings("", s.char_world);
    try testing.expect(s.char_book == null);

    s.adoptCharCard("not json");
    try testing.expectEqualStrings("", s.char_world);
}

fn loadForAllocTest(a: Allocator) !void {
    var s = WorldInfoStore.init(a);
    defer s.deinit();
    try s.loadBookFromJson("test-lore", fixture_book);
    const b = s.bookByFileId("test-lore").?;
    _ = try s.createEntry(b);
    try s.setEntryKeys(b, "3", .key, "one,two");
    const body = try s.serializeForEdit(b);
    a.free(body);
    try s.loadCharBookFromJson(fixture_v2_book);
}

test "store cleans up on every allocation failure" {
    try std.testing.checkAllAllocationFailures(testing.allocator, loadForAllocTest, .{});
}

// ---- engine candidates (w3-wi-engine) ----------------------------------------------------------

const tiny_book_a =
    \\{"name":"Alpha Book","entries":{
    \\"0":{"uid":0,"key":["a"],"content":"A-low","order":10},
    \\"1":{"uid":1,"key":["b"],"content":"A-high","order":200}
    \\}}
;
const tiny_book_b =
    \\{"name":"Beta Book","entries":{"0":{"uid":0,"key":["c"],"content":"B-only","order":50}}}
;

test "setFromSettings reads scan depth and recursion beside the budget" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    s.setFromSettings(
        \\{"world_info_settings":{"world_info_budget":40,"world_info_depth":7,"world_info_recursive":true}}
    );
    try testing.expectEqual(@as(i64, 40), s.budget);
    try testing.expectEqual(@as(i64, 7), s.scan_depth);
    try testing.expect(s.recursive);
}

test "mergeState writes depth and recursion back under the classic keys" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    s.setFromSettings("{}");
    s.scan_depth = 5;
    s.recursive = true;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var root: std.json.ObjectMap = .empty;
    try s.mergeState(arena.allocator(), &root);
    const ws = root.get("world_info_settings").?.object;
    try testing.expectEqual(@as(i64, 5), ws.get("world_info_depth").?.integer);
    try testing.expectEqual(true, ws.get("world_info_recursive").?.bool);
}

test "resolveBookRef finds a loaded book by file id or by display name" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.setBookListFromJson(
        \\[{"file_id":"alpha-lore","name":"Alpha Book"}]
    );
    try s.loadBookFromJson("alpha-lore", tiny_book_a);
    try testing.expect(s.resolveBookRef("alpha-lore") != null);
    try testing.expect(s.resolveBookRef("Alpha Book") != null);
    try testing.expect(s.resolveBookRef("missing") == null);
    try testing.expect(s.resolveBookRef("") == null);
    try testing.expectEqualStrings("alpha-lore", s.resolveRefFileId("Alpha Book").?);
    try testing.expectEqualStrings("raw-ref", s.resolveRefFileId("raw-ref").?);
}

test "collectActive orders chat then char then global, order descending, without duplicates" {
    var s = WorldInfoStore.init(testing.allocator);
    defer s.deinit();
    try s.loadBookFromJson("alpha-lore", tiny_book_a);
    try s.loadBookFromJson("beta-lore", tiny_book_b);
    s.setChatWorld("alpha-lore");
    _ = try s.toggleGlobal("beta-lore");
    _ = try s.toggleGlobal("alpha-lore");

    const got = try s.collectActive(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("A-high", got[0].content);
    try testing.expectEqualStrings("A-low", got[1].content);
    try testing.expectEqualStrings("B-only", got[2].content);
}

test "collectActive cleans up on every allocation failure" {
    try std.testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: Allocator) !void {
            var s = WorldInfoStore.init(a);
            defer s.deinit();
            try s.loadBookFromJson("alpha-lore", tiny_book_a);
            // toggleGlobal, not setChatWorld: the latter is an infallible UI setter that swallows
            // its own OOM by design, which this harness would flag.
            _ = try s.toggleGlobal("alpha-lore");
            const got = try s.collectActive(a);
            a.free(got);
        }
    }.run, .{});
}
