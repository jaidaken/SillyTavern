//! Tokenizer selection for the textgen send path: which tokenizer the classic getTokenizerBestMatch
//! resolves for a backend (tokenizers.js:286), the encode endpoint each one maps to, and a token-count
//! cache. Pure and zx-free so it joins the native `zig build test` aggregator (ZX5); char_api owns the
//! async encode fetches and the round-trip barrier, this file owns the WHICH and the memoization.

const std = @import("std");

/// The tokenizers the textgen path resolves to. `remote_textgen` proxies to the backend's own
/// tokenizer (the exact count for a live llama.cpp / tabby / vllm / ...); the rest are SillyTavern's
/// bundled local models chosen by model-name substring. `none` means no tokenizer (guess only).
pub const Tokenizer = enum {
    none,
    remote_textgen,
    llama,
    llama3,
    mistral,
    gemma,
    nemo,
    deepseek,
    yi,
    jamba,
    command_r,
    command_a,
    qwen2,
};

pub const remote_encode_path = "/api/tokenizers/remote/textgenerationwebui/encode";

/// The tokenizer the classic getTokenizerBestMatch picks for a textgen backend: a connected, supported
/// backend with no prior tokenizer error uses its own remote tokenizer, else the model name's substring
/// picks a local model, defaulting to llama. `model` is the classic getTextGenModel() || online_status;
/// `connected` and `had_error` gate the remote tier (case-insensitive on the model, like the original).
pub fn bestMatch(api_type: []const u8, model: []const u8, connected: bool, had_error: bool) Tokenizer {
    if (connected and !had_error and remoteSupported(api_type)) return .remote_textgen;
    return localMatch(model);
}

/// TEXTGEN_TOKENIZERS (tokenizers.js:1307) minus ooba: the client does not track ooba's hasValidEndpoint
/// gate, which getTokenizerBestMatch requires for ooba, so an ooba backend falls to the local tier.
fn remoteSupported(api_type: []const u8) bool {
    const set = [_][]const u8{ "llamacpp", "tabby", "koboldcpp", "vllm", "aphrodite" };
    for (set) |t| if (std.mem.eql(u8, api_type, t)) return true;
    return false;
}

/// The local model-substring ladder, in the classic order (tokenizers.js:328): the first match wins, so
/// mistral is tested before nemo and llama3 before the llama default.
fn localMatch(model: []const u8) Tokenizer {
    if (containsCi(model, "llama3") or containsCi(model, "llama-3")) return .llama3;
    if (containsCi(model, "mistral") or containsCi(model, "mixtral")) return .mistral;
    if (containsCi(model, "gemma")) return .gemma;
    if (containsCi(model, "nemo") or containsCi(model, "pixtral")) return .nemo;
    if (containsCi(model, "deepseek")) return .deepseek;
    if (containsCi(model, "yi")) return .yi;
    if (containsCi(model, "jamba")) return .jamba;
    if (containsCi(model, "command-r")) return .command_r;
    if (containsCi(model, "command-a")) return .command_a;
    if (containsCi(model, "qwen2")) return .qwen2;
    return .llama;
}

/// The encode endpoint for a LOCAL tokenizer. `none`/`remote_textgen` have none here (remote uses
/// `remote_encode_path` with a body carrying the backend url + model).
pub fn localEncodePath(t: Tokenizer) []const u8 {
    return switch (t) {
        .llama => "/api/tokenizers/llama/encode",
        .llama3 => "/api/tokenizers/llama3/encode",
        .mistral => "/api/tokenizers/mistral/encode",
        .gemma => "/api/tokenizers/gemma/encode",
        .nemo => "/api/tokenizers/nemo/encode",
        .deepseek => "/api/tokenizers/deepseek/encode",
        .yi => "/api/tokenizers/yi/encode",
        .jamba => "/api/tokenizers/jamba/encode",
        .command_r => "/api/tokenizers/command-r/encode",
        .command_a => "/api/tokenizers/command-a/encode",
        .qwen2 => "/api/tokenizers/qwen2/encode",
        .none, .remote_textgen => "",
    };
}

/// A per-string token-count cache keyed by the tokenizer identity (stock tokenCache keys on tokenizer +
/// model + string hash), so the send path re-fetches only the turns new since the last send. The
/// discriminator folds the tokenizer and, for remote, the model, so a model swap invalidates cleanly.
pub const TokenCache = struct {
    const Key = struct { h: u64, disc: u64 };
    map: std.AutoHashMapUnmanaged(Key, usize) = .empty,

    pub fn deinit(self: *TokenCache, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }

    pub fn get(self: *const TokenCache, text: []const u8, disc: u64) ?usize {
        return self.map.get(.{ .h = std.hash.Wyhash.hash(0, text), .disc = disc });
    }

    pub fn put(self: *TokenCache, alloc: std.mem.Allocator, text: []const u8, disc: u64, count: usize) void {
        self.map.put(alloc, .{ .h = std.hash.Wyhash.hash(0, text), .disc = disc }, count) catch {};
    }
};

/// The cache discriminator for a resolved tokenizer: the enum ordinal, plus the model hash for the
/// remote tier where the count depends on the loaded backend model.
pub fn cacheDisc(t: Tokenizer, model: []const u8) u64 {
    const base: u64 = @intFromEnum(t);
    if (t == .remote_textgen) return base ^ (std.hash.Wyhash.hash(0xd15c, model) << 4);
    return base;
}

fn containsCi(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (haystack.len < needle_lower.len) return false;
    var i: usize = 0;
    outer: while (i + needle_lower.len <= haystack.len) : (i += 1) {
        for (needle_lower, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != c) continue :outer;
        }
        return true;
    }
    return false;
}

const testing = std.testing;

test "bestMatch takes the remote tokenizer for a connected supported backend" {
    try testing.expectEqual(Tokenizer.remote_textgen, bestMatch("llamacpp", "anything", true, false));
    try testing.expectEqual(Tokenizer.remote_textgen, bestMatch("tabby", "", true, false));
    try testing.expectEqual(Tokenizer.remote_textgen, bestMatch("vllm", "Qwen2", true, false));
}

test "bestMatch falls to the local model match when not connected, on error, or unsupported" {
    // Not connected -> local; the model substring still picks the family.
    try testing.expectEqual(Tokenizer.llama3, bestMatch("llamacpp", "Meta-Llama-3.1-8B", false, false));
    // A prior tokenizer error drops the remote tier.
    try testing.expectEqual(Tokenizer.llama, bestMatch("llamacpp", "some-model", true, true));
    // ooba is unsupported for the remote tier here (no endpoint-validation signal).
    try testing.expectEqual(Tokenizer.mistral, bestMatch("ooba", "mistral-7b", true, false));
    // ollama/huggingface are not in TEXTGEN_TOKENIZERS.
    try testing.expectEqual(Tokenizer.gemma, bestMatch("ollama", "gemma-2-9b", true, false));
}

test "localMatch walks the classic substring ladder first-match-wins and is case-insensitive" {
    try testing.expectEqual(Tokenizer.llama3, localMatch("Meta-Llama-3.1"));
    try testing.expectEqual(Tokenizer.llama3, localMatch("LLAMA3-70B"));
    try testing.expectEqual(Tokenizer.mistral, localMatch("Mixtral-8x7B"));
    // mistral is tested before nemo, so a Mistral-Nemo name resolves mistral, matching the original.
    try testing.expectEqual(Tokenizer.mistral, localMatch("Mistral-Nemo-12B"));
    try testing.expectEqual(Tokenizer.nemo, localMatch("nemo-instruct"));
    try testing.expectEqual(Tokenizer.deepseek, localMatch("DeepSeek-R1"));
    try testing.expectEqual(Tokenizer.yi, localMatch("Yi-34B"));
    try testing.expectEqual(Tokenizer.jamba, localMatch("jamba-mini"));
    try testing.expectEqual(Tokenizer.command_r, localMatch("command-r-plus"));
    try testing.expectEqual(Tokenizer.command_a, localMatch("command-a-03"));
    try testing.expectEqual(Tokenizer.qwen2, localMatch("Qwen2-7B"));
    // llama2 and unknowns fall through to the llama default.
    try testing.expectEqual(Tokenizer.llama, localMatch("llama-2-13b"));
    try testing.expectEqual(Tokenizer.llama, localMatch(""));
    try testing.expectEqual(Tokenizer.llama, localMatch("some-unknown-model"));
}

test "localEncodePath maps every local tokenizer to its encode route" {
    try testing.expectEqualStrings("/api/tokenizers/llama/encode", localEncodePath(.llama));
    try testing.expectEqualStrings("/api/tokenizers/command-r/encode", localEncodePath(.command_r));
    try testing.expectEqualStrings("/api/tokenizers/qwen2/encode", localEncodePath(.qwen2));
    try testing.expectEqualStrings("", localEncodePath(.remote_textgen));
    try testing.expectEqualStrings("", localEncodePath(.none));
}

test "TokenCache stores and separates counts by discriminator" {
    var cache: TokenCache = .{};
    defer cache.deinit(testing.allocator);
    const llama_disc = cacheDisc(.llama, "");
    const llama3_disc = cacheDisc(.llama3, "");
    try testing.expectEqual(@as(?usize, null), cache.get("Rita: hi\n", llama_disc));
    cache.put(testing.allocator, "Rita: hi\n", llama_disc, 5);
    try testing.expectEqual(@as(?usize, 5), cache.get("Rita: hi\n", llama_disc));
    // The same string under a different tokenizer is a different entry.
    try testing.expectEqual(@as(?usize, null), cache.get("Rita: hi\n", llama3_disc));
}

test "cacheDisc separates remote counts by model but locals only by tokenizer" {
    try testing.expect(cacheDisc(.remote_textgen, "model-a") != cacheDisc(.remote_textgen, "model-b"));
    try testing.expectEqual(cacheDisc(.llama, "model-a"), cacheDisc(.llama, "model-b"));
}
