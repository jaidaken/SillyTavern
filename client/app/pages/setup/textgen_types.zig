//! The self-hosted textgen backend types the connections panel offers, and the secrets.json key each
//! one stores its API key under. Pure and zx-free so it joins the native `zig build test` aggregator
//! (ZX5); connection.zig holds the DOM, fetch and persist side.
//!
//! The server does NOT bound this set: `/api/settings/set-connection` (src/endpoints/settings.js:369)
//! accepts any non-empty api_type that is not a prototype key, so this table is the only constraint.
//! Keys mirror SECRET_KEYS in src/endpoints/secrets.js; ollama authenticates with no key there.

const std = @import("std");
const nav = @import("../nav/dropdown_nav.zig");

pub const Type = struct {
    value: []const u8,
    label: []const u8,
    /// The secrets.json key, or null for a type that takes no API key.
    secret_key: ?[]const u8,
};

pub const types: []const Type = &.{
    .{ .value = "llamacpp", .label = "llama.cpp", .secret_key = "api_key_llamacpp" },
    .{ .value = "koboldcpp", .label = "KoboldCpp", .secret_key = "api_key_koboldcpp" },
    .{ .value = "ollama", .label = "Ollama", .secret_key = null },
    .{ .value = "tabby", .label = "TabbyAPI", .secret_key = "api_key_tabby" },
    .{ .value = "ooba", .label = "Text Generation WebUI", .secret_key = "api_key_ooba" },
    .{ .value = "vllm", .label = "vLLM", .secret_key = "api_key_vllm" },
    .{ .value = "aphrodite", .label = "Aphrodite", .secret_key = "api_key_aphrodite" },
    .{ .value = "huggingface", .label = "HuggingFace TGI", .secret_key = "api_key_huggingface" },
};

/// The type a fresh install connects as, matching the panel's llama.cpp placeholder URL.
pub const default_type = "llamacpp";

/// The dropdown's option list, derived from `types` so the two can never drift apart.
pub const options: []const nav.Option = blk: {
    var arr: [types.len]nav.Option = undefined;
    for (types, 0..) |t, i| arr[i] = .{ .value = t.value, .label = t.label };
    const frozen = arr;
    break :blk &frozen;
};

pub fn find(value: []const u8) ?Type {
    for (types) |t| {
        if (std.mem.eql(u8, t.value, value)) return t;
    }
    return null;
}

pub fn isKnown(value: []const u8) bool {
    return find(value) != null;
}

/// The secrets.json key holding this type's API key. Null when the type is unknown to the table or
/// takes no key, which is the panel's signal to hide the key field entirely.
pub fn secretKeyFor(value: []const u8) ?[]const u8 {
    const t = find(value) orelse return null;
    return t.secret_key;
}

test "every_offered_type_has_a_distinct_value_and_a_nonempty_label" {
    for (types, 0..) |t, i| {
        try std.testing.expect(t.value.len > 0);
        try std.testing.expect(t.label.len > 0);
        for (types[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, t.value, other.value));
        }
    }
    try std.testing.expectEqual(@as(usize, 8), types.len);
}

test "the_options_list_mirrors_the_type_table_entry_for_entry" {
    try std.testing.expectEqual(types.len, options.len);
    for (types, options) |t, opt| {
        try std.testing.expectEqualStrings(t.value, opt.value);
        try std.testing.expectEqualStrings(t.label, opt.label);
    }
}

test "the_default_type_is_one_the_table_offers" {
    try std.testing.expect(isKnown(default_type));
    try std.testing.expectEqualStrings("llamacpp", default_type);
}

test "find_resolves_a_known_value_and_rejects_an_unknown_one" {
    try std.testing.expectEqualStrings("Ollama", find("ollama").?.label);
    try std.testing.expectEqualStrings("TabbyAPI", find("tabby").?.label);
    try std.testing.expectEqual(@as(?Type, null), find("gpt-4"));
    try std.testing.expectEqual(@as(?Type, null), find(""));
    try std.testing.expect(!isKnown("llamacpp_"));
}

test "every_keyed_type_maps_to_its_sillytavern_secret_key_and_ollama_maps_to_none" {
    try std.testing.expectEqualStrings("api_key_llamacpp", secretKeyFor("llamacpp").?);
    try std.testing.expectEqualStrings("api_key_koboldcpp", secretKeyFor("koboldcpp").?);
    try std.testing.expectEqualStrings("api_key_tabby", secretKeyFor("tabby").?);
    try std.testing.expectEqualStrings("api_key_ooba", secretKeyFor("ooba").?);
    try std.testing.expectEqualStrings("api_key_vllm", secretKeyFor("vllm").?);
    try std.testing.expectEqualStrings("api_key_aphrodite", secretKeyFor("aphrodite").?);
    try std.testing.expectEqualStrings("api_key_huggingface", secretKeyFor("huggingface").?);

    // No OLLAMA entry exists in SECRET_KEYS, so the panel must not offer a key field for it.
    try std.testing.expectEqual(@as(?[]const u8, null), secretKeyFor("ollama"));
    try std.testing.expectEqual(@as(?[]const u8, null), secretKeyFor("unknown-backend"));
}

test "every_secret_key_follows_the_api_key_type_convention_the_server_stores_under" {
    var buf: [64]u8 = undefined;
    for (types) |t| {
        const key = t.secret_key orelse continue;
        const expected = try std.fmt.bufPrint(&buf, "api_key_{s}", .{t.value});
        try std.testing.expectEqualStrings(expected, key);
    }
}
