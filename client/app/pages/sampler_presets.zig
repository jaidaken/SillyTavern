//! The sampler presets the AI Response Configuration panel picks from, and the body a save posts.
//!
//! WHERE THEY COME FROM. `/api/settings/get` answers `{settings, ...payload}` (src/endpoints/
//! settings.js:423,428), so the two preset arrays are SIBLINGS of the `settings` string, not keys
//! inside it. They arrive as PARALLEL ARRAYS built by readPresetsFromDirectory (settings.js:100-113):
//! `textgenerationwebui_preset_names` holds the file names with the extension stripped, and
//! `textgenerationwebui_presets` holds each file's RAW TEXT. The server calls JSON.parse on a file
//! only to VALIDATE it, then pushes the untouched text, so index i of one array names index i of the
//! other and every body is a string this module parses itself.
//!
//! WHY EVERY READ HERE DEGRADES. These are user-writable files: hand-edited, written by other tools,
//! and validated by the server as parseable JSON and nothing more. A typed std.json parse would fail
//! the WHOLE parse on one odd field, which is the bug class that emptied the character list and the
//! recent-chats list twice. So the ladder is: an unreadable FIELD costs that field, an unreadable
//! PRESET costs that preset, and neither ever costs the list.
//!
//! ABSENT IS THE NORMAL CASE, so absent must KEEP. A key a preset does not carry leaves that sampler
//! at its current value rather than snapping it to a spec default. This is not defensive coding, it
//! is the classic client's own rule (`if (preset.genamt !== undefined)`, public/script.js:8102-8112)
//! and the shipped presets need it: all three of them
//! (default/content/presets/textgen/{Default,Neutral,Deterministic}.json, 61 keys each) carry the
//! five samplers and carry NEITHER budget dial, so a snap-to-default would silently reset the user's
//! response length and context size every time they picked one.
//!
//! THE TWO BUDGET DIALS ARE SPELLED DIFFERENTLY IN A PRESET. A preset says `genamt`/`max_length`
//! where the settings blob says `amount_gen`/`max_context`; samplers.presetKey owns that mapping. A
//! preset SAVED by the classic client does carry the pair (preset-manager.js:739-740) even though the
//! shipped ones do not, so reading and writing them under the preset spelling is what keeps a preset
//! saved here loadable there and the other way round.
//!
//! zx-free so `zig build test` proves the parse, the apply and the save contract natively (ZX5);
//! config_state.zig owns the fetch, the arena and the DOM.

const std = @import("std");

const samplers = @import("./samplers.zig");

const Allocator = std.mem.Allocator;

/// The envelope keys the two parallel arrays arrive under.
const names_key = "textgenerationwebui_preset_names";
const bodies_key = "textgenerationwebui_presets";

/// The apiId `/api/presets/save` routes a textgen preset by (src/endpoints/presets.js:25). The server
/// 400s on an apiId it cannot map to a folder, so this string is contract, not decoration.
pub const api_id = "textgenerationwebui";

pub const Preset = struct {
    name: []const u8,
    /// The preset file's parsed object. Borrowed from the arena `parseList` was handed; it stays
    /// valid until that arena is freed.
    obj: std.json.ObjectMap,
};

/// Keys that must never reach a saved preset file, whatever the base carried.
///
/// `preset` names the file rather than describing samplers, and would fight the blob's own
/// selected-preset key on the next load. The other four NAME A HOST, and a preset file is meant to be
/// SHARED: shipping someone else's `api_server` inside one is the leak this whole family invites. The
/// base is a preset rather than the live blob (see buildSaveBody), so it should never hold these, but
/// "should never" is a claim about somebody else's file. A preset can be hand-edited, shared by
/// another user, or written by a client whose own denylist missed a key, and the clone keeps EVERY key
/// the panel does not model (that is the point of it). So the guard is applied rather than assumed.
///
/// The classic client carries the same idea as a 50-entry filteredKeys list
/// (public/scripts/preset-manager.js:677-731). The other 45 were read and deliberately left out: the
/// ~14 `*_model` keys name a MODEL rather than a host, `can_use_*`/`derived` are runtime-derived
/// capability flags, and `streaming`/`seed`/`n`/`enabled`/`truncation_length` are session state.
/// Leaking any of those out of a shared preset is cosmetic; leaking a host is not. Five keys we can
/// each state a reason for beats fifty that must stay correct forever.
const forbidden_keys = [_][]const u8{ "preset", "api_server", "type", "server_urls", "streaming_url" };

pub const Parsed = struct {
    presets: []Preset,
    /// How many entries named a preset the panel could not use. The USER is told this count: a file
    /// they can see on disk that never appears in the picker, explained only in a console they will
    /// never open, is the silent failure this whole parse exists to avoid.
    unreadable: usize,
};

/// The presets in a `/api/settings/get` envelope, in the server's order.
///
/// Returns an empty list rather than an error for every malformed shape: a settings response the
/// client cannot read must cost the preset list and nothing else. Only OOM propagates.
pub fn parseList(a: Allocator, envelope: []const u8) Allocator.Error!Parsed {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, envelope, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .presets = &.{}, .unreadable = 0 },
    };
    const obj = switch (root) {
        .object => |o| o,
        else => return .{ .presets = &.{}, .unreadable = 0 },
    };
    const names = arrayField(obj, names_key) orelse return .{ .presets = &.{}, .unreadable = 0 };
    const bodies = arrayField(obj, bodies_key) orelse return .{ .presets = &.{}, .unreadable = 0 };

    // Zip to the shorter array: a name with no body (or the other way round) names nothing the panel
    // could apply, so the pair is what makes a preset, not either array's length.
    const n = @min(names.len, bodies.len);
    var out: std.ArrayList(Preset) = .empty;
    errdefer out.deinit(a);
    var unreadable: usize = 0;
    for (0..n) |i| {
        const name = jsonStr(names[i]);
        if (name.len == 0) {
            unreadable += 1;
            continue;
        }
        const body = jsonStr(bodies[i]);
        if (body.len == 0) {
            unreadable += 1;
            continue;
        }
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                unreadable += 1;
                continue;
            },
        };
        // A body that parses to something other than an object (a file holding `42` or `[1,2]`)
        // can never apply a single sampler, so it is dropped rather than offered as a control that
        // silently does nothing. The user is told the COUNT; only the reason stays in the log.
        const preset_obj = switch (parsed) {
            .object => |o| o,
            else => {
                unreadable += 1;
                continue;
            },
        };
        try out.append(a, .{ .name = name, .obj = preset_obj });
    }
    return .{ .presets = try out.toOwnedSlice(a), .unreadable = unreadable };
}

/// The preset name the settings blob records as selected, or null when it records none.
///
/// `textgenerationwebui_settings.preset` is the classic client's own key for this
/// (public/scripts/textgen-settings.js:379), so reading it here is what makes the picker open on the
/// preset the other client last chose rather than on a fork-local guess. Borrowed from `a`.
pub fn selectedNameFrom(a: Allocator, settings_str: []const u8) Allocator.Error!?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, settings_str, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const tg = switch (obj.get("textgenerationwebui_settings") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const name = jsonStr(tg.get("preset") orelse return null);
    return if (name.len == 0) null else name;
}

/// The preset named `name`, or null when the list has no such preset.
pub fn find(list: []const Preset, name: []const u8) ?Preset {
    for (list) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Apply a preset's samplers onto `values`, returning how many the preset actually carried.
///
/// Every value lands through samplers.clamp, so a hand-edited file cannot push a sampler past its
/// spec range any more than a typed one can. A key the preset omits, or carries in a shape that is
/// not a number, leaves that sampler at its CURRENT value (see the header).
pub fn applyTo(preset: Preset, values: *samplers.Values) usize {
    var applied: usize = 0;
    for (samplers.specs, 0..) |spec, i| {
        const node = preset.obj.get(samplers.presetKey(spec)) orelse continue;
        const raw = numberOf(node) orelse continue;
        values[i] = samplers.clamp(spec, raw);
        applied += 1;
    }
    return applied;
}

/// The `/api/presets/save` POST body: `{"name":...,"apiId":"textgenerationwebui","preset":{...}}`.
/// The server reads exactly these three field names and 400s without name or preset
/// (src/endpoints/presets.js:44-47), so the shape is pinned by a test here as well as by the gate.
///
/// `base` is the preset the panel last applied. Saving copies it and overwrites only the keys the
/// panel owns, so a user who picks a 61-key preset, nudges the temperature and saves keeps the other
/// 56 samplers instead of shipping a 7-key file. No preset applied yet -> the body carries the
/// panel's samplers alone. Every spec is written under its PRESET spelling (genamt/max_length for the
/// two dials), which is the pair the classic client writes on its own save
/// (public/scripts/preset-manager.js:739-740), so a preset saved here loads there unchanged.
pub fn buildSaveBody(a: Allocator, name: []const u8, base: ?std.json.ObjectMap, values: samplers.Values) Allocator.Error![]u8 {
    // DIVERGENCE FROM THE CLASSIC CLIENT, deliberate (lead-weighed 2026-07-16). Classic bases a save
    // on the LIVE textgen settings object and then DELETES a 50-entry filteredKeys list from it
    // (preset-manager.js:730-735), because that object also holds the backend connection: one wrong
    // entry in that hand-maintained list writes the user's server URL into a file whose whole purpose
    // is to be shared. We base on the last-applied PRESET instead, which never held a connection, so
    // no exclusion list has to stay correct forever. The cost is that a save with no preset picked
    // carries only the seven samplers this panel actually showed the user, rather than the ~48 it
    // never modelled. Both clients KEEP absent keys, so a seven-key preset destroys nothing.
    var preset: std.json.ObjectMap = if (base) |b| try b.clone(a) else .empty;
    for (forbidden_keys) |k| _ = preset.orderedRemove(k);
    for (samplers.specs, 0..) |spec, i| {
        const v = samplers.clamp(spec, values[i]);
        const node: std.json.Value = if (spec.kind == .int)
            .{ .integer = @intFromFloat(v) }
        else
            .{ .float = v };
        try preset.put(a, samplers.presetKey(spec), node);
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(a, "name", .{ .string = name });
    try root.put(a, "apiId", .{ .string = api_id });
    try root.put(a, "preset", .{ .object = preset });
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});
}

fn arrayField(obj: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    return switch (obj.get(key) orelse return null) {
        .array => |arr| arr.items,
        else => null,
    };
}

/// The string a loosely-typed field carries, or "" for any other shape (char_data.jsonStr's rule,
/// kept identical so both loose parses degrade the same way).
fn jsonStr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string, .number_string => |s| s,
        else => "",
    };
}

/// The number a loosely-typed field carries, or null when it is not one.
///
/// A quoted number counts: these files are hand-edited and the classic client's own blob stores the
/// author's-note depth as the string "2", so a string that parses IS the value (gate row C-CFG-10 is
/// the precedent). A null, a bool, an object, an array or a string that is not a number is not a
/// value, and NaN/inf are rejected here rather than passed to clamp so the field reads as absent and
/// keeps the sampler it found.
fn numberOf(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| finite(f),
        .integer => |n| @floatFromInt(n),
        .number_string, .string => |s| parseNumber(s),
        else => null,
    };
}

fn parseNumber(s: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return null;
    return finite(std.fmt.parseFloat(f64, trimmed) catch return null);
}

fn finite(f: f64) ?f64 {
    if (std.math.isNan(f) or std.math.isInf(f)) return null;
    return f;
}

const testing = std.testing;

/// A preset key's value as a number, for the tests. Asserting the VALUE rather than the json union
/// tag is the point: a whole float stringifies as `4` and parses back as .integer, so a tag
/// assertion would pin an encoding detail the wire does not carry.
fn numAt(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    return numberOf(obj.get(key) orelse return null);
}

test "parseList reads the parallel arrays, pairing name i with body i" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body =
        \\{"settings":"{\"main_api\":\"textgenerationwebui\"}",
        \\ "textgenerationwebui_preset_names":["Deterministic","Big O"],
        \\ "textgenerationwebui_presets":["{\"temp\":0,\"top_k\":1}","{\"temp\":0.87,\"top_k\":40}"]}
    ;
    const list = (try parseList(a, body)).presets;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("Deterministic", list[0].name);
    try testing.expectEqualStrings("Big O", list[1].name);
    // The pairing is what a parallel-array shape gets wrong first: prove body i went with name i.
    try testing.expectEqual(@as(?f64, 0), numAt(list[0].obj, "temp"));
    try testing.expectEqual(@as(?f64, 0.87), numAt(list[1].obj, "temp"));
}

test "parseList survives an envelope that is not JSON, an object, or has no arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try parseList(a, "not json at all")).presets.len);
    try testing.expectEqual(@as(usize, 0), (try parseList(a, "[1,2,3]")).presets.len);
    try testing.expectEqual(@as(usize, 0), (try parseList(a, "{}")).presets.len);
    // The arrays present but the wrong shape entirely.
    try testing.expectEqual(@as(usize, 0), (try parseList(a,
        \\{"textgenerationwebui_preset_names":"Deterministic","textgenerationwebui_presets":"{}"}
    )).presets.len);
}

test "a preset with an unreadable name or body costs that preset and never the list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Entry 1 has a NUMERIC name, entry 2 a null body, entry 3 a body that is valid JSON but not an
    // object, entry 4 a body that is not JSON. Every one of them must cost itself alone.
    const body =
        \\{"textgenerationwebui_preset_names":["Good",41,"NullBody","NotAnObject","Unparseable","AlsoGood"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.5}","{\"temp\":9}",null,"42","{oops","{\"temp\":1.2}"]}
    ;
    const list = (try parseList(a, body)).presets;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("Good", list[0].name);
    try testing.expectEqualStrings("AlsoGood", list[1].name);
    try testing.expectEqual(@as(?f64, 1.2), numAt(list[1].obj, "temp"));
}

test "parseList zips to the shorter array when the two disagree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const more_names =
        \\{"textgenerationwebui_preset_names":["A","B","C"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.1}"]}
    ;
    const list = (try parseList(a, more_names)).presets;
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("A", list[0].name);

    const more_bodies =
        \\{"textgenerationwebui_preset_names":["A"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.1}","{\"temp\":0.2}","{\"temp\":0.3}"]}
    ;
    const list2 = (try parseList(a, more_bodies)).presets;
    try testing.expectEqual(@as(usize, 1), list2.len);
}

test "applyTo sets every sampler the preset carries and clamps each one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body =
        \\{"textgenerationwebui_preset_names":["Wild"],
        \\ "textgenerationwebui_presets":["{\"temp\":900,\"top_p\":0.95,\"top_k\":40.6,\"min_p\":0.05,\"rep_pen\":1.1}"]}
    ;
    const list = (try parseList(a, body)).presets;
    var v = samplers.defaults();
    try testing.expectEqual(@as(usize, 5), applyTo(list[0], &v));
    // 900 is far past temp's max of 4: a hostile file clamps exactly as a typed value does.
    try testing.expectEqual(@as(f64, 4), v[samplers.indexOf("temp").?]);
    try testing.expectEqual(@as(f64, 0.95), v[samplers.indexOf("top_p").?]);
    // An int-kind spec rounds.
    try testing.expectEqual(@as(f64, 41), v[samplers.indexOf("top_k").?]);
    try testing.expectEqual(@as(f64, 0.05), v[samplers.indexOf("min_p").?]);
    try testing.expectEqual(@as(f64, 1.1), v[samplers.indexOf("rep_pen").?]);
}

test "a hostile field costs that field and the preset still applies the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // temp quoted (a hand-edit: still a number, so it applies), top_p null, top_k an object,
    // min_p a bool, rep_pen a string that is not a number. Only temp may move.
    const body =
        \\{"textgenerationwebui_preset_names":["Hostile"],
        \\ "textgenerationwebui_presets":["{\"temp\":\"0.55\",\"top_p\":null,\"top_k\":{\"a\":1},\"min_p\":true,\"rep_pen\":\"warm\"}"]}
    ;
    const list = (try parseList(a, body)).presets;
    try testing.expectEqual(@as(usize, 1), list.len);

    var v = samplers.defaults();
    v[samplers.indexOf("top_p").?] = 0.9;
    v[samplers.indexOf("top_k").?] = 40;
    v[samplers.indexOf("min_p").?] = 0.02;
    v[samplers.indexOf("rep_pen").?] = 1.15;
    try testing.expectEqual(@as(usize, 1), applyTo(list[0], &v));
    try testing.expectEqual(@as(f64, 0.55), v[samplers.indexOf("temp").?]);
    // Each unreadable field kept the value it found rather than snapping to a default.
    try testing.expectEqual(@as(f64, 0.9), v[samplers.indexOf("top_p").?]);
    try testing.expectEqual(@as(f64, 40), v[samplers.indexOf("top_k").?]);
    try testing.expectEqual(@as(f64, 0.02), v[samplers.indexOf("min_p").?]);
    try testing.expectEqual(@as(f64, 1.15), v[samplers.indexOf("rep_pen").?]);
}

test "a shipped preset carries no budget dials and so moves neither" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Deterministic.json's real shape: the five samplers, no genamt, no max_length. The user's
    // response length and context size must survive picking it.
    const body =
        \\{"textgenerationwebui_preset_names":["Deterministic"],
        \\ "textgenerationwebui_presets":["{\"temp\":0,\"top_p\":0,\"top_k\":1,\"min_p\":0,\"rep_pen\":1}"]}
    ;
    const list = (try parseList(a, body)).presets;
    var v = samplers.defaults();
    v[samplers.indexOf("max_tokens").?] = 320;
    v[samplers.indexOf("max_context").?] = 16384;
    try testing.expectEqual(@as(usize, 5), applyTo(list[0], &v));
    try testing.expectEqual(@as(f64, 320), v[samplers.indexOf("max_tokens").?]);
    try testing.expectEqual(@as(f64, 16384), v[samplers.indexOf("max_context").?]);
    try testing.expectEqual(@as(f64, 0), v[samplers.indexOf("temp").?]);
}

test "a preset saved by the classic client moves the dials under genamt and max_length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The shape preset-manager.js:739-740 writes. The preset spells the dials differently from the
    // blob, so reading them under the BLOB names would silently ignore both.
    const body =
        \\{"textgenerationwebui_preset_names":["Saved By Classic"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.3,\"genamt\":320,\"max_length\":16384}"]}
    ;
    const list = (try parseList(a, body)).presets;
    var v = samplers.defaults();
    try testing.expectEqual(@as(usize, 3), applyTo(list[0], &v));
    try testing.expectEqual(@as(f64, 320), v[samplers.indexOf("max_tokens").?]);
    try testing.expectEqual(@as(f64, 16384), v[samplers.indexOf("max_context").?]);
    try testing.expectEqual(@as(f64, 0.3), v[samplers.indexOf("temp").?]);
}

test "the blob spelling of a dial inside a preset is not the preset spelling and is ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // amount_gen/max_context are what the BLOB calls them. A preset carrying those names is not
    // saying anything the classic client would act on, so neither dial moves.
    const body =
        \\{"textgenerationwebui_preset_names":["Wrong Spelling"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.3,\"amount_gen\":4096,\"max_context\":131072}"]}
    ;
    const list = (try parseList(a, body)).presets;
    var v = samplers.defaults();
    try testing.expectEqual(@as(usize, 1), applyTo(list[0], &v));
    try testing.expectEqual(@as(f64, 512), v[samplers.indexOf("max_tokens").?]);
    try testing.expectEqual(@as(f64, 8192), v[samplers.indexOf("max_context").?]);
}

test "selectedNameFrom reads the classic client's own selected-preset key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const blob =
        \\{"main_api":"textgenerationwebui","textgenerationwebui_settings":{"type":"llamacpp","preset":"Big O","temp":0.8}}
    ;
    try testing.expectEqualStrings("Big O", (try selectedNameFrom(a, blob)).?);
}

test "selectedNameFrom returns null for every shape that does not name a preset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A blob is user-writable too: none of these may cost anything but the selection.
    try testing.expectEqual(@as(?[]const u8, null), try selectedNameFrom(a, "not json"));
    try testing.expectEqual(@as(?[]const u8, null), try selectedNameFrom(a, "[]"));
    try testing.expectEqual(@as(?[]const u8, null), try selectedNameFrom(a, "{}"));
    try testing.expectEqual(@as(?[]const u8, null), try selectedNameFrom(a, "{\"textgenerationwebui_settings\":\"nope\"}"));
    try testing.expectEqual(@as(?[]const u8, null), try selectedNameFrom(a, "{\"textgenerationwebui_settings\":{}}"));
    try testing.expectEqual(@as(?[]const u8, null), try selectedNameFrom(a, "{\"textgenerationwebui_settings\":{\"preset\":null}}"));
    try testing.expectEqual(@as(?[]const u8, null), try selectedNameFrom(a, "{\"textgenerationwebui_settings\":{\"preset\":42}}"));
    try testing.expectEqual(@as(?[]const u8, null), try selectedNameFrom(a, "{\"textgenerationwebui_settings\":{\"preset\":\"\"}}"));
}

test "picking a preset cannot reach the backend connection in the blob" {
    // The hazard a preset picker invites: apply by overwriting the textgen section and the user's
    // backend disappears the moment they pick "Deterministic". applyTo cannot express that (its only
    // mutable argument is a [7]f64), and samplers.merge writes in place, but the whole CHAIN is what
    // has to hold, so this drives it end to end rather than trusting either half.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const list = (try parseList(a,
        \\{"textgenerationwebui_preset_names":["Deterministic"],
        \\ "textgenerationwebui_presets":["{\"temp\":0,\"top_p\":0,\"top_k\":1,\"min_p\":0,\"rep_pen\":1}"]}
    )).presets;

    var blob = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"main_api":"textgenerationwebui","amount_gen":384,
        \\ "textgenerationwebui_settings":{"type":"llamacpp","server_urls":{"llamacpp":"http://127.0.0.1:5001"},"temp":0.8}}
    , .{});

    var v = samplers.defaults();
    v[samplers.indexOf("max_tokens").?] = 384;
    _ = applyTo(list[0], &v);
    try samplers.merge(a, &blob.object, v);

    const tg = blob.object.get("textgenerationwebui_settings").?.object;
    try testing.expectEqualStrings("llamacpp", tg.get("type").?.string);
    try testing.expectEqualStrings("http://127.0.0.1:5001", tg.get("server_urls").?.object.get("llamacpp").?.string);
    try testing.expectEqual(@as(?f64, 0), numAt(tg, "temp"));
    // The dial the preset never mentioned kept the user's value through the whole chain.
    try testing.expectEqual(@as(i64, 384), blob.object.get("amount_gen").?.integer);
}

test "parseList counts the entries it could not use so the user can be told" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try parseList(a,
        \\{"textgenerationwebui_preset_names":["Good",41,"NullBody","NotAnObject","Unparseable"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.5}","{\"temp\":9}",null,"42","{oops"]}
    );
    try testing.expectEqual(@as(usize, 1), parsed.presets.len);
    try testing.expectEqual(@as(usize, 4), parsed.unreadable);

    // A wholly good list reports nothing to apologise for.
    const clean = try parseList(a,
        \\{"textgenerationwebui_preset_names":["A"],"textgenerationwebui_presets":["{\"temp\":0.1}"]}
    );
    try testing.expectEqual(@as(usize, 0), clean.unreadable);
}

test "a saved preset never carries the backend connection out of the base" {
    // The base is a preset, which should never hold a connection, but "should never" is a claim
    // about a file somebody else may have written. The clone keeps every unmodelled key by design,
    // so the guard has to be applied rather than assumed: a preset file is meant to be SHARED and
    // shipping a real api_server inside one is the leak this family invites.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const list = (try parseList(a,
        \\{"textgenerationwebui_preset_names":["Leaky"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.4,\"tfs\":0.9,\"preset\":\"Some Other Name\",\"api_server\":\"http://192.168.1.10:5001\",\"type\":\"koboldcpp\",\"server_urls\":{\"koboldcpp\":\"http://192.168.1.10:5001\"},\"streaming_url\":\"ws://192.168.1.10:5005/api/v1/stream\"}"]}
    )).presets;
    const body = try buildSaveBody(a, "My Preset", list[0].obj, samplers.defaults());
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const preset = parsed.object.get("preset").?.object;

    for (forbidden_keys) |k| {
        try testing.expect(preset.get(k) == null);
    }
    // The address must not survive anywhere in the serialized body, under any key.
    try testing.expect(std.mem.indexOf(u8, body, "192.168.1.10") == null);
    // A genuine sampler the panel does not model still survives, or the guard would be a blunt
    // instrument that strips the thing the base exists to preserve.
    try testing.expectEqual(@as(?f64, 0.9), numAt(preset, "tfs"));
    try testing.expectEqual(@as(?f64, 1.0), numAt(preset, "temp"));
}

test "a saved preset never names itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A hand-edited file may carry `preset`; the classic client filters the same key out of its own
    // save. Saving from it must not carry the name through, or the file would fight the blob's own
    // selected-preset key on the next load.
    const list = (try parseList(a,
        \\{"textgenerationwebui_preset_names":["Named"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.4,\"preset\":\"Some Other Name\",\"tfs\":0.9}"]}
    )).presets;
    const body = try buildSaveBody(a, "My Preset", list[0].obj, samplers.defaults());
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const preset = parsed.object.get("preset").?.object;
    try testing.expect(preset.get("preset") == null);
    // The name still rides the ENVELOPE, which is where the server reads it from.
    try testing.expectEqualStrings("My Preset", parsed.object.get("name").?.string);
    // and the unmodelled key it sat beside still survives.
    try testing.expectEqual(@as(?f64, 0.9), numAt(preset, "tfs"));
}

test "find matches by name and rejects an absent one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = (try parseList(a,
        \\{"textgenerationwebui_preset_names":["A","B"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.1}","{\"temp\":0.2}"]}
    )).presets;
    try testing.expectEqual(@as(?f64, 0.2), numAt(find(list, "B").?.obj, "temp"));
    try testing.expect(find(list, "nope") == null);
    try testing.expect(find(&.{}, "A") == null);
}

test "buildSaveBody carries the three field names the server reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var v = samplers.defaults();
    v[samplers.indexOf("temp").?] = 0.72;
    const body = try buildSaveBody(a, "My Preset", null, v);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    try testing.expectEqualStrings("My Preset", parsed.object.get("name").?.string);
    try testing.expectEqualStrings("textgenerationwebui", parsed.object.get("apiId").?.string);
    const preset = parsed.object.get("preset").?.object;
    try testing.expectEqual(@as(?f64, 0.72), numAt(preset, "temp"));
    // All seven specs, each under its PRESET spelling. The blob spellings must not appear, or the
    // classic client would read the file and find no budget dials at all.
    try testing.expectEqual(@as(usize, 7), preset.count());
    try testing.expectEqual(@as(?f64, 512), numAt(preset, "genamt"));
    try testing.expectEqual(@as(?f64, 8192), numAt(preset, "max_length"));
    try testing.expect(preset.get("amount_gen") == null);
    try testing.expect(preset.get("max_context") == null);
}

test "a preset saved here reloads through applyTo with every sampler intact" {
    // The round-trip that matters: what this client saves is what it (and the classic client) reads
    // back. buildSaveBody writes preset spellings, applyTo reads them.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var v = samplers.defaults();
    v[samplers.indexOf("temp").?] = 0.72;
    v[samplers.indexOf("top_k").?] = 40;
    v[samplers.indexOf("min_p").?] = 0.05;
    v[samplers.indexOf("max_tokens").?] = 320;
    v[samplers.indexOf("max_context").?] = 16384;
    const body = try buildSaveBody(a, "Round Trip", null, v);

    const saved = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const reloaded = Preset{ .name = "Round Trip", .obj = saved.object.get("preset").?.object };
    var back = samplers.defaults();
    try testing.expectEqual(@as(usize, 7), applyTo(reloaded, &back));
    try testing.expectEqualSlices(f64, &v, &back);
}

test "buildSaveBody keeps the base preset's other samplers and overwrites only the panel's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const list = (try parseList(a,
        \\{"textgenerationwebui_preset_names":["Big O"],
        \\ "textgenerationwebui_presets":["{\"temp\":0.87,\"tfs\":0.68,\"dry_multiplier\":0.8,\"add_bos_token\":true}"]}
    )).presets;
    var v = samplers.defaults();
    v[samplers.indexOf("temp").?] = 1.25;
    const body = try buildSaveBody(a, "My Big O", list[0].obj, v);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const preset = parsed.object.get("preset").?.object;

    // The panel's key wins.
    try testing.expectEqual(@as(?f64, 1.25), numAt(preset, "temp"));
    // The 3 keys the panel does not model survive, or saving would silently strip 56 samplers.
    try testing.expectEqual(@as(?f64, 0.68), numAt(preset, "tfs"));
    try testing.expectEqual(@as(?f64, 0.8), numAt(preset, "dry_multiplier"));
    try testing.expectEqual(true, preset.get("add_bos_token").?.bool);
    // 4 base keys, one of which (temp) the panel overwrote, plus the panel's other 6.
    try testing.expectEqual(@as(usize, 10), preset.count());
}

test "buildSaveBody clamps a hostile live value before it can reach a saved file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var v = samplers.defaults();
    v[samplers.indexOf("temp").?] = 900;
    v[samplers.indexOf("top_k").?] = 40.6;
    const body = try buildSaveBody(a, "Wild", null, v);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const preset = parsed.object.get("preset").?.object;
    try testing.expectEqual(@as(?f64, 4), numAt(preset, "temp"));
    try testing.expectEqual(@as(?f64, 41), numAt(preset, "top_k"));
}

test "numberOf reads every numeric shape and refuses every other" {
    try testing.expectEqual(@as(?f64, 0.8), numberOf(.{ .float = 0.8 }));
    try testing.expectEqual(@as(?f64, 40), numberOf(.{ .integer = 40 }));
    try testing.expectEqual(@as(?f64, 0.8), numberOf(.{ .string = "0.8" }));
    try testing.expectEqual(@as(?f64, 0.8), numberOf(.{ .number_string = "0.8" }));
    try testing.expectEqual(@as(?f64, 0.8), numberOf(.{ .string = " 0.8 " }));
    try testing.expectEqual(@as(?f64, null), numberOf(.null));
    try testing.expectEqual(@as(?f64, null), numberOf(.{ .bool = true }));
    try testing.expectEqual(@as(?f64, null), numberOf(.{ .string = "warm" }));
    try testing.expectEqual(@as(?f64, null), numberOf(.{ .string = "" }));
    try testing.expectEqual(@as(?f64, null), numberOf(.{ .string = "nan" }));
    try testing.expectEqual(@as(?f64, null), numberOf(.{ .string = "inf" }));
    try testing.expectEqual(@as(?f64, null), numberOf(.{ .float = std.math.nan(f64) }));
    try testing.expectEqual(@as(?f64, null), numberOf(.{ .float = std.math.inf(f64) }));
    try testing.expectEqual(@as(?f64, null), numberOf(.{ .array = std.json.Array.init(testing.allocator) }));
}

test "parseList survives arbitrary bytes without panicking or leaking" {
    // ZT3/ZT4: parseList reads a server response the user's own files feed, so its always-on
    // property is that NO input produces a panic, a leak, or a preset with an empty name. The seed
    // is fixed so a failure replays.
    var prng = std.Random.DefaultPrng.init(0x5A3C_1F09);
    const rand = prng.random();
    const alphabet = "{}[]\",:0123456789.eE-+ \\ntfulsxyz_";

    var buf: [192]u8 = undefined;
    for (0..3000) |_| {
        const len = rand.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const list = (try parseList(arena.allocator(), buf[0..len])).presets;
        for (list) |p| {
            try testing.expect(p.name.len > 0);
            var v = samplers.defaults();
            // Whatever survived the parse must also be safe to apply, and must never leave a
            // sampler outside its own spec range.
            _ = applyTo(p, &v);
            for (samplers.specs, 0..) |spec, i| {
                try testing.expect(v[i] >= spec.min and v[i] <= spec.max);
            }
        }
    }
}

test "parseList cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, _: u8) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const list = try parseList(arena.allocator(),
                \\{"textgenerationwebui_preset_names":["A","B"],
                \\ "textgenerationwebui_presets":["{\"temp\":0.1}","{\"temp\":0.2}"]}
            );
            _ = list;
        }
    }.run, .{@as(u8, 0)});
}

test "buildSaveBody cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, _: u8) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const body = try buildSaveBody(arena.allocator(), "N", null, samplers.defaults());
            _ = body;
        }
    }.run, .{@as(u8, 0)});
}
