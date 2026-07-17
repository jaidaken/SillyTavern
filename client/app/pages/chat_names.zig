//! Pure name and index logic for the chat manager (chat_actions.zig): the .jsonl suffix rules the
//! server routes disagree on, destination-name minting for duplicate/branch with 409 retry, and the
//! 1-based branch-point parse. zx-free so `zig build test` proves it; the network flows that use
//! these are browser-verified through the interactions gate.
//!
//! Suffix contract (audited src/endpoints/chats.js 2026-07-17): /get, /duplicate and /branch resolve
//! through ChatRef.solo, which APPENDS .jsonl itself, so they take the bare stem. /rename stats its
//! arguments verbatim, so it needs the suffix. /delete appends .jsonl only when path.extname finds
//! none, and a stem with a dot ("v1.2 quest") defeats that, so delete gets the explicit suffix too.

const std = @import("std");

pub const suffix = ".jsonl";

/// The stem with the explicit .jsonl suffix, for /rename and /delete.
pub fn withJsonl(alloc: std.mem.Allocator, stem: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, suffix });
}

/// The bare stem: drops one trailing .jsonl if present. /recent hands file names WITH the suffix
/// while /search hands stems; every flow normalizes through this before talking to a route.
pub fn stemOf(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, suffix)) return name[0 .. name.len - suffix.len];
    return name;
}

pub const NameKind = enum { copy, branch };

/// Destination name for a duplicate or a branch. Attempt 0 is the plain form; a 409 from the server
/// (name exists) bumps the attempt for " 2", " 3", ... so a retry loop is deterministic and cheap.
/// The branch form carries the 1-based branch point so two branches at different points never collide.
pub fn mintName(alloc: std.mem.Allocator, stem: []const u8, kind: NameKind, point_1b: usize, attempt: usize) ![]u8 {
    return switch (kind) {
        .copy => if (attempt == 0)
            std.fmt.allocPrint(alloc, "{s} copy", .{stem})
        else
            std.fmt.allocPrint(alloc, "{s} copy {d}", .{ stem, attempt + 1 }),
        .branch => if (attempt == 0)
            std.fmt.allocPrint(alloc, "{s} branch {d}", .{ stem, point_1b })
        else
            std.fmt.allocPrint(alloc, "{s} branch {d} v{d}", .{ stem, point_1b, attempt + 1 }),
    };
}

/// Parses the user's 1-based branch point against the chat's message count. Returns the 0-based
/// index for the /branch route, or null when the input is not a number in [1, count].
pub fn parseBranchPoint(input: []const u8, count: usize) ?usize {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    const n = std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (n < 1 or n > count) return null;
    return n - 1;
}

const testing = std.testing;

test "with_jsonl_appends_and_stem_of_strips_exactly_one_suffix" {
    const a = testing.allocator;
    const full = try withJsonl(a, "old adventure");
    defer a.free(full);
    try testing.expectEqualStrings("old adventure.jsonl", full);
    try testing.expectEqualStrings("old adventure", stemOf(full));
    try testing.expectEqualStrings("old adventure", stemOf("old adventure"));
    try testing.expectEqualStrings("nested.jsonl", stemOf("nested.jsonl.jsonl"));
}

test "stem_of_leaves_dots_that_are_not_the_suffix_alone" {
    try testing.expectEqualStrings("v1.2 quest", stemOf("v1.2 quest"));
    try testing.expectEqualStrings("v1.2 quest", stemOf("v1.2 quest.jsonl"));
}

test "mint_name_copy_is_plain_then_numbered_on_retry" {
    const a = testing.allocator;
    const first = try mintName(a, "keep me", .copy, 0, 0);
    defer a.free(first);
    try testing.expectEqualStrings("keep me copy", first);
    const second = try mintName(a, "keep me", .copy, 0, 1);
    defer a.free(second);
    try testing.expectEqualStrings("keep me copy 2", second);
    const ninth = try mintName(a, "keep me", .copy, 0, 8);
    defer a.free(ninth);
    try testing.expectEqualStrings("keep me copy 9", ninth);
}

test "mint_name_branch_carries_the_point_and_versions_on_retry" {
    const a = testing.allocator;
    const first = try mintName(a, "keep me", .branch, 3, 0);
    defer a.free(first);
    try testing.expectEqualStrings("keep me branch 3", first);
    const retry = try mintName(a, "keep me", .branch, 3, 1);
    defer a.free(retry);
    try testing.expectEqualStrings("keep me branch 3 v2", retry);
}

test "mint_name_cleans_up_on_every_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, mintNameCheck, .{});
}

fn mintNameCheck(alloc: std.mem.Allocator) !void {
    const n = try mintName(alloc, "stem", .branch, 2, 1);
    alloc.free(n);
}

test "parse_branch_point_maps_one_based_input_to_zero_based_index" {
    try testing.expectEqual(@as(?usize, 0), parseBranchPoint("1", 3));
    try testing.expectEqual(@as(?usize, 2), parseBranchPoint(" 3 ", 3));
    try testing.expectEqual(@as(?usize, null), parseBranchPoint("0", 3));
    try testing.expectEqual(@as(?usize, null), parseBranchPoint("4", 3));
    try testing.expectEqual(@as(?usize, null), parseBranchPoint("", 3));
    try testing.expectEqual(@as(?usize, null), parseBranchPoint("two", 3));
    try testing.expectEqual(@as(?usize, null), parseBranchPoint("1", 0));
}
