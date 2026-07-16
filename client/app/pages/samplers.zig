//! The sampler set the AI Response Configuration panel edits, and the settings-blob keys each one
//! round-trips through.
//!
//! These are the SAME keys generate.extractConnection already mines (`textgenerationwebui_settings.temp`
//! and friends, plus `amount_gen`/`max_context` at the blob root), which is what makes the panel
//! shared with the classic client rather than a fork-local copy: a value set here shows up there and
//! the other way round. The table below is the single source of truth for the key, the scope, the
//! numeric kind, and the range; the panel, the persistence and the clamp all read it.
//!
//! Seven of the classic client's ~55 textgen parameters. The set is the one that changes the reply
//! rather than the one that fills a panel: creativity (temp), nucleus/tail cutoffs (top_p, top_k,
//! min_p), repetition (rep_pen), and the two budget dials the prompt window is computed from
//! (max_tokens, max_context). The rest stay at their backend defaults and are named in the report as
//! deferred depth rather than half-rendered here.
//!
//! zx-free so `zig build test` proves the clamp and the merge natively (ZX5); config_state.zig owns
//! the DOM and the settings round-trip.

const std = @import("std");

const generate = @import("./generate.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum { float, int };

/// Where the key lives in the settings blob. `textgen` is inside `textgenerationwebui_settings`,
/// `root` is at the blob's top level (the classic client puts the two budget dials there).
pub const Scope = enum { textgen, root };

pub const Spec = struct {
    /// The control's data-sampler value and its `st-sampler-<id>` localStorage suffix.
    id: []const u8,
    label: []const u8,
    /// The settings-blob key. Not always the id: the response length is `amount_gen` in the blob.
    key: []const u8,
    scope: Scope,
    kind: Kind,
    min: f64,
    max: f64,
    step: f64,
    /// The backend-neutral default, matching generate.extractConnection's fallbacks so a blob with
    /// the key absent and a panel that never wrote it agree on the value.
    default: f64,
    hint: []const u8,
};

pub const specs = [_]Spec{
    .{ .id = "temp", .label = "Temperature", .key = "temp", .scope = .textgen, .kind = .float, .min = 0, .max = 4, .step = 0.01, .default = 1.0, .hint = "Higher is more random. 0 is deterministic." },
    .{ .id = "top_p", .label = "Top P", .key = "top_p", .scope = .textgen, .kind = .float, .min = 0, .max = 1, .step = 0.01, .default = 1.0, .hint = "Keeps the smallest set of tokens whose probabilities sum to this. 1 disables it." },
    .{ .id = "top_k", .label = "Top K", .key = "top_k", .scope = .textgen, .kind = .int, .min = 0, .max = 200, .step = 1, .default = 0, .hint = "Keeps only this many likeliest tokens. 0 disables it." },
    .{ .id = "min_p", .label = "Min P", .key = "min_p", .scope = .textgen, .kind = .float, .min = 0, .max = 1, .step = 0.01, .default = 0, .hint = "Drops tokens below this fraction of the likeliest one. 0 disables it." },
    .{ .id = "rep_pen", .label = "Repetition penalty", .key = "rep_pen", .scope = .textgen, .kind = .float, .min = 1, .max = 2, .step = 0.01, .default = 1.0, .hint = "Penalises repeats. 1 disables it." },
    .{ .id = "max_tokens", .label = "Response length", .key = "amount_gen", .scope = .root, .kind = .int, .min = 16, .max = 8192, .step = 16, .default = 512, .hint = "Tokens the model may generate per reply." },
    .{ .id = "max_context", .label = "Context size", .key = "max_context", .scope = .root, .kind = .int, .min = 512, .max = 262144, .step = 256, .default = 8192, .hint = "Tokens the prompt window is budgeted against." },
};

/// A slice view for `{for}` in the panel (ZX1: the loop target must be a slice).
pub const specs_slice: []const Spec = &specs;

/// One value per spec, positionally. A plain array rather than a named struct so the panel, the
/// clamp and the merge can all walk `specs` and stay in step when a sampler is added.
pub const Values = [specs.len]f64;

pub fn indexOf(id: []const u8) ?usize {
    for (specs, 0..) |s, i| {
        if (std.mem.eql(u8, s.id, id)) return i;
    }
    return null;
}

pub fn defaults() Values {
    var v: Values = undefined;
    for (specs, 0..) |s, i| v[i] = s.default;
    return v;
}

/// Clamps into the spec's range and quantises an int-kind value, so a hand-typed or hostile stored
/// value cannot reach the request body. A NaN reads as the default: it would compare false against
/// both bounds and slip through a naive clamp.
pub fn clamp(spec: Spec, v: f64) f64 {
    if (std.math.isNan(v)) return spec.default;
    const bounded = std.math.clamp(v, spec.min, spec.max);
    return if (spec.kind == .int) @round(bounded) else bounded;
}

/// Parses a control's text value, returning null when it is not a number at all (the caller keeps
/// the current value rather than snapping the slider to zero mid-drag).
pub fn parse(spec: Spec, text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const raw = std.fmt.parseFloat(f64, trimmed) catch return null;
    if (std.math.isNan(raw) or std.math.isInf(raw)) return null;
    return clamp(spec, raw);
}

/// The value as the control and the request body should read it: an int-kind renders with no
/// fractional part, a float-kind to two decimals (the step is 0.01, so more digits are noise).
pub fn format(alloc: Allocator, spec: Spec, v: f64) Allocator.Error![]u8 {
    if (spec.kind == .int) return std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(clamp(spec, v)))});
    return std.fmt.allocPrint(alloc, "{d:.2}", .{clamp(spec, v)});
}

/// The live values mined from the active connection, so the panel opens on what send actually uses.
pub fn fromConnection(conn: generate.Connection) Values {
    var v = defaults();
    v[indexOf("temp").?] = conn.temperature;
    v[indexOf("top_p").?] = conn.top_p;
    v[indexOf("top_k").?] = @floatFromInt(conn.top_k);
    v[indexOf("min_p").?] = conn.min_p;
    v[indexOf("rep_pen").?] = conn.rep_pen;
    v[indexOf("max_tokens").?] = @floatFromInt(conn.max_tokens);
    v[indexOf("max_context").?] = @floatFromInt(conn.max_context);
    for (specs, 0..) |s, i| v[i] = clamp(s, v[i]);
    return v;
}

/// Writes the values onto a live connection, so a panel edit reaches the next send with no settings
/// refetch and no reload.
pub fn applyToConnection(values: Values, conn: *generate.Connection) void {
    conn.temperature = values[indexOf("temp").?];
    conn.top_p = values[indexOf("top_p").?];
    conn.top_k = @intFromFloat(values[indexOf("top_k").?]);
    conn.min_p = values[indexOf("min_p").?];
    conn.rep_pen = values[indexOf("rep_pen").?];
    conn.max_tokens = @intFromFloat(values[indexOf("max_tokens").?]);
    conn.max_context = @intFromFloat(values[indexOf("max_context").?]);
}

/// Merges the samplers into the settings object about to be saved, IN PLACE, preserving every other
/// key. The textgen sub-object is created only when absent: it also holds `type` and `server_urls`,
/// which the connection panel owns, so replacing it wholesale would drop the user's backend.
pub fn merge(a: Allocator, root_obj: *std.json.ObjectMap, values: Values) Allocator.Error!void {
    var tg: std.json.ObjectMap = switch (root_obj.get("textgenerationwebui_settings") orelse std.json.Value{ .object = .empty }) {
        .object => |o| o,
        else => .empty,
    };
    for (specs, 0..) |s, i| {
        const v = clamp(s, values[i]);
        const node: std.json.Value = if (s.kind == .int)
            .{ .integer = @intFromFloat(v) }
        else
            .{ .float = v };
        switch (s.scope) {
            .textgen => try tg.put(a, s.key, node),
            .root => try root_obj.put(a, s.key, node),
        }
    }
    try root_obj.put(a, "textgenerationwebui_settings", .{ .object = tg });
}

const testing = std.testing;

test "specs ids and keys are unique and every default sits inside its own range" {
    for (specs, 0..) |a, i| {
        for (specs, 0..) |b, j| {
            if (i == j) continue;
            try testing.expect(!std.mem.eql(u8, a.id, b.id));
        }
        try testing.expect(a.default >= a.min and a.default <= a.max);
        try testing.expect(a.max > a.min);
        try testing.expect(a.step > 0);
    }
}

test "sampler defaults match the connection extractor's fallbacks" {
    // The two must agree or a fresh panel would silently rewrite the prompt budget on first save.
    const v = defaults();
    try testing.expectEqual(@as(f64, 1.0), v[indexOf("temp").?]);
    try testing.expectEqual(@as(f64, 1.0), v[indexOf("top_p").?]);
    try testing.expectEqual(@as(f64, 0), v[indexOf("top_k").?]);
    try testing.expectEqual(@as(f64, 0), v[indexOf("min_p").?]);
    try testing.expectEqual(@as(f64, 1.0), v[indexOf("rep_pen").?]);
    try testing.expectEqual(@as(f64, 512), v[indexOf("max_tokens").?]);
    try testing.expectEqual(@as(f64, 8192), v[indexOf("max_context").?]);
}

test "clamp bounds, rounds ints, and rejects NaN to the default" {
    const temp = specs[indexOf("temp").?];
    try testing.expectEqual(@as(f64, 4), clamp(temp, 99));
    try testing.expectEqual(@as(f64, 0), clamp(temp, -3));
    try testing.expectEqual(@as(f64, 0.8), clamp(temp, 0.8));
    try testing.expectEqual(temp.default, clamp(temp, std.math.nan(f64)));

    const top_k = specs[indexOf("top_k").?];
    try testing.expectEqual(@as(f64, 41), clamp(top_k, 40.6));
    try testing.expectEqual(@as(f64, 200), clamp(top_k, 1e9));
}

test "parse reads a control value and refuses a non-number" {
    const temp = specs[indexOf("temp").?];
    try testing.expectEqual(@as(?f64, 0.8), parse(temp, " 0.8 "));
    try testing.expectEqual(@as(?f64, 4), parse(temp, "1000"));
    try testing.expectEqual(@as(?f64, null), parse(temp, ""));
    try testing.expectEqual(@as(?f64, null), parse(temp, "abc"));
    try testing.expectEqual(@as(?f64, null), parse(temp, "nan"));
    try testing.expectEqual(@as(?f64, null), parse(temp, "inf"));
}

test "format renders ints without a fraction and floats to two places" {
    const temp = specs[indexOf("temp").?];
    const t = try format(testing.allocator, temp, 0.8);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("0.80", t);

    const top_k = specs[indexOf("top_k").?];
    const k = try format(testing.allocator, top_k, 40.0);
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("40", k);

    const ctx = specs[indexOf("max_context").?];
    const c = try format(testing.allocator, ctx, 16384);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("16384", c);
}

test "fromConnection and applyToConnection round-trip every sampler" {
    const conn = generate.Connection{
        .api_type = "",
        .api_server = "",
        .max_context = 16384,
        .max_tokens = 320,
        .temperature = 0.8,
        .top_p = 0.95,
        .top_k = 40,
        .min_p = 0.05,
        .rep_pen = 1.1,
    };
    const v = fromConnection(conn);
    try testing.expectEqual(@as(f64, 0.8), v[indexOf("temp").?]);
    try testing.expectEqual(@as(f64, 40), v[indexOf("top_k").?]);
    try testing.expectEqual(@as(f64, 16384), v[indexOf("max_context").?]);

    var target = conn;
    target.temperature = 0;
    target.max_context = 0;
    applyToConnection(v, &target);
    try testing.expectEqual(conn.temperature, target.temperature);
    try testing.expectEqual(conn.top_p, target.top_p);
    try testing.expectEqual(conn.top_k, target.top_k);
    try testing.expectEqual(conn.min_p, target.min_p);
    try testing.expectEqual(conn.rep_pen, target.rep_pen);
    try testing.expectEqual(conn.max_tokens, target.max_tokens);
    try testing.expectEqual(conn.max_context, target.max_context);
}

test "fromConnection clamps a hostile stored connection" {
    const conn = generate.Connection{
        .api_type = "",
        .api_server = "",
        .max_context = -5,
        .max_tokens = 1 << 40,
        .temperature = 900,
        .top_p = -1,
        .top_k = -7,
        .min_p = 0.05,
        .rep_pen = 1.1,
    };
    const v = fromConnection(conn);
    try testing.expectEqual(@as(f64, 4), v[indexOf("temp").?]);
    try testing.expectEqual(@as(f64, 0), v[indexOf("top_p").?]);
    try testing.expectEqual(@as(f64, 0), v[indexOf("top_k").?]);
    try testing.expectEqual(@as(f64, 512), v[indexOf("max_context").?]);
    try testing.expectEqual(@as(f64, 8192), v[indexOf("max_tokens").?]);
}

test "merge writes both scopes and keeps the connection keys intact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const blob =
        \\{"main_api":"textgenerationwebui","unrelated":"keep me",
        \\ "textgenerationwebui_settings":{"type":"llamacpp","server_urls":{"llamacpp":"http://x"},"temp":0.1}}
    ;
    var root = try std.json.parseFromSliceLeaky(std.json.Value, a, blob, .{});

    var v = defaults();
    v[indexOf("temp").?] = 0.8;
    v[indexOf("top_k").?] = 40;
    v[indexOf("max_context").?] = 16384;
    try merge(a, &root.object, v);

    const tg = root.object.get("textgenerationwebui_settings").?.object;
    // The connection panel's keys must survive a sampler save.
    try testing.expectEqualStrings("llamacpp", tg.get("type").?.string);
    try testing.expect(tg.get("server_urls") != null);
    try testing.expectEqual(@as(f64, 0.8), tg.get("temp").?.float);
    try testing.expectEqual(@as(i64, 40), tg.get("top_k").?.integer);
    try testing.expectEqual(@as(i64, 16384), root.object.get("max_context").?.integer);
    try testing.expectEqual(@as(i64, 512), root.object.get("amount_gen").?.integer);
    try testing.expectEqualStrings("keep me", root.object.get("unrelated").?.string);
    try testing.expectEqualStrings("textgenerationwebui", root.object.get("main_api").?.string);
}

test "merge creates the textgen object when the blob has none or it is mistyped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var empty = std.json.Value{ .object = .empty };
    try merge(a, &empty.object, defaults());
    try testing.expectEqual(@as(f64, 1.0), empty.object.get("textgenerationwebui_settings").?.object.get("temp").?.float);

    var wrong = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"textgenerationwebui_settings\":\"nope\"}", .{});
    try merge(a, &wrong.object, defaults());
    try testing.expect(wrong.object.get("textgenerationwebui_settings").? == .object);
}

test "merge output re-mines through extractConnection unchanged" {
    // The round-trip that matters: what the panel saves is what the next boot's send reads.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"main_api":"textgenerationwebui","textgenerationwebui_settings":{"type":"llamacpp","server_urls":{"llamacpp":"http://x"}}}
    , .{});
    var v = defaults();
    v[indexOf("temp").?] = 0.75;
    v[indexOf("top_k").?] = 40;
    v[indexOf("min_p").?] = 0.05;
    v[indexOf("max_tokens").?] = 320;
    v[indexOf("max_context").?] = 16384;
    try merge(a, &root.object, v);

    const saved = try std.json.Stringify.valueAlloc(a, root, .{});
    const conn = try generate.extractConnection(testing.allocator, saved);
    defer generate.freeConnection(testing.allocator, conn);
    try testing.expectEqual(@as(f64, 0.75), conn.temperature);
    try testing.expectEqual(@as(i64, 40), conn.top_k);
    try testing.expectEqual(@as(f64, 0.05), conn.min_p);
    try testing.expectEqual(@as(i64, 320), conn.max_tokens);
    try testing.expectEqual(@as(i64, 16384), conn.max_context);
    try testing.expectEqualStrings("llamacpp", conn.api_type);
    try testing.expectEqualStrings("http://x", conn.api_server);
}

test "merge cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, _: u8) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            var root = std.json.Value{ .object = .empty };
            try merge(a, &root.object, defaults());
        }
    }.run, .{@as(u8, 0)});
}
