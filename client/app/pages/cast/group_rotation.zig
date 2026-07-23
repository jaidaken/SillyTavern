//! Pure member-rotation logic for group sends (C-GRP 3c-B). Given the enabled roster (the
//! group_store activationOrder output: members minus muted, in list order) and an activation
//! strategy, selectMembers produces the ordered index list of members to generate for; Rotation
//! then walks that list one seal at a time and owns duped copies of the member strings, because
//! store slices are invalidated by any reload while a generation is in flight.
//!
//! zx-free so the whole module runs under `zig build test` (ZX5 split); the impure driver that
//! streams each turn lives in group_send.zig.
//!
//! Deliberate divergences from the classic client (group-chats.js activateNaturalOrder), all
//! toward determinism since a headless-proven client cannot assert on Math.random:
//! - no talkativeness roll; a member with no mention activates only via the fallback.
//! - fallbacks pick the FIRST eligible member, never a random one.
//! - an unrecognized strategy value degrades to natural (stock silently activates nobody).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Wire values match the group JSON's activation_strategy (groups.js /create default 0).
pub const ActivationStrategy = enum(u8) { natural = 0, list = 1, manual = 2, pooled = 3, _ };

/// Wire values match the group JSON's generation_mode. Only swap ships this cut; the driver
/// treats anything else as swap rather than guessing at card joining.
pub const GenerationMode = enum(u8) { swap = 0, append = 1, append_disabled = 2, _ };

pub const Member = struct {
    avatar: []const u8,
    name: []const u8,
};

/// The newest chat message, as the selection sees it. A user turn never bans anyone; a member
/// turn bans its own speaker from replying to itself unless the group allows self-responses.
pub const LastMsg = struct {
    name: []const u8 = "",
    is_user: bool = false,
};

pub const SelectOpts = struct {
    strategy: ActivationStrategy = .natural,
    /// The text that triggers activation: the user's input when they typed, else the last
    /// non-system message body (stock generateGroupWrapper:990).
    activation_text: []const u8 = "",
    last: ?LastMsg = null,
    allow_self_responses: bool = false,
    /// True when the user's own send triggered this rotation; stock never self-bans then.
    is_user_input: bool = true,
    /// The explicit member trigger (stock force_chid): overrides every strategy when valid.
    manual_pick: ?usize = null,
};

/// The ordered roster indices to generate for. Owned by the caller.
///
/// natural: members mentioned by name in the activation text, in input-word order, then a
/// first-eligible fallback so a send always draws one reply. list: every roster member in list
/// order, deduped by avatar. manual: only an explicit pick replies to user input. pooled
/// (approximation this cut): one member, preferring anyone but the last speaker.
pub fn selectMembers(alloc: Allocator, roster: []const Member, opts: SelectOpts) Allocator.Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(alloc);
    if (roster.len == 0) return out.toOwnedSlice(alloc);

    if (opts.manual_pick) |pick| {
        if (pick < roster.len) {
            try out.append(alloc, pick);
            return out.toOwnedSlice(alloc);
        }
    }

    const banned = bannedName(opts);
    switch (opts.strategy) {
        .list => try appendListOrder(alloc, &out, roster),
        .manual => if (!opts.is_user_input) try out.append(alloc, 0),
        .pooled => try out.append(alloc, pooledIndex(roster, opts, banned)),
        // Unknown wire values land here too: natural is the stock default strategy.
        .natural, _ => try appendNaturalOrder(alloc, &out, roster, opts, banned),
    }
    return out.toOwnedSlice(alloc);
}

fn bannedName(opts: SelectOpts) ?[]const u8 {
    if (opts.allow_self_responses or opts.is_user_input) return null;
    const last = opts.last orelse return null;
    if (last.is_user or last.name.len == 0) return null;
    return last.name;
}

fn isBanned(m: Member, banned: ?[]const u8) bool {
    const b = banned orelse return false;
    return std.mem.eql(u8, m.name, b);
}

fn appendListOrder(alloc: Allocator, out: *std.ArrayList(usize), roster: []const Member) Allocator.Error!void {
    for (roster, 0..) |m, i| {
        if (avatarSeen(out.items, roster, m.avatar)) continue;
        try out.append(alloc, i);
    }
}

fn avatarSeen(selected: []const usize, roster: []const Member, avatar: []const u8) bool {
    for (selected) |i| {
        if (std.mem.eql(u8, roster[i].avatar, avatar)) return true;
    }
    return false;
}

fn appendNaturalOrder(alloc: Allocator, out: *std.ArrayList(usize), roster: []const Member, opts: SelectOpts, banned: ?[]const u8) Allocator.Error!void {
    var words = WordIterator{ .text = opts.activation_text };
    while (words.next()) |w| {
        for (roster, 0..) |m, i| {
            if (isBanned(m, banned)) continue;
            if (!nameHasWord(m.name, w)) continue;
            if (!avatarSeen(out.items, roster, m.avatar)) try out.append(alloc, i);
            break;
        }
    }
    if (out.items.len == 0) try out.append(alloc, firstEligible(roster, banned));
}

/// One member, preferring anyone but the last speaker: the deterministic first cut of stock
/// pooled order (which tracks everyone who spoke since the last user turn and rolls a die).
fn pooledIndex(roster: []const Member, opts: SelectOpts, banned: ?[]const u8) usize {
    const avoid: []const u8 = if (opts.last) |l| (if (!l.is_user) l.name else "") else "";
    for (roster, 0..) |m, i| {
        if (isBanned(m, banned)) continue;
        if (avoid.len > 0 and std.mem.eql(u8, m.name, avoid)) continue;
        return i;
    }
    return firstEligible(roster, banned);
}

/// First non-banned member, else index 0: a send against a non-empty roster always draws one
/// reply (stock falls back onto the full pool too, so an all-banned roster still answers).
fn firstEligible(roster: []const Member, banned: ?[]const u8) usize {
    for (roster, 0..) |m, i| {
        if (!isBanned(m, banned)) return i;
    }
    return 0;
}

/// ASCII word runs of [A-Za-z0-9_], the same class stock's extractAllWords \b\w+\b regex sees.
const WordIterator = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(self: *WordIterator) ?[]const u8 {
        while (self.pos < self.text.len and !isWordByte(self.text[self.pos])) self.pos += 1;
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        while (self.pos < self.text.len and isWordByte(self.text[self.pos])) self.pos += 1;
        return self.text[start..self.pos];
    }
};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn nameHasWord(name: []const u8, word: []const u8) bool {
    var it = WordIterator{ .text = name };
    while (it.next()) |w| {
        if (std.ascii.eqlIgnoreCase(w, word)) return true;
    }
    return false;
}

/// The queue a group send walks: one member generates at a time, advance() moves on after each
/// seal, stop() drops everyone still waiting while the in-flight member keeps its attribution
/// for the seal-time append. Owns duped member strings (store slices die on any reload).
pub const Rotation = struct {
    alloc: Allocator,
    members: []Member = &.{},
    idx: usize = 0,
    stopped: bool = false,

    pub fn init(alloc: Allocator, roster: []const Member, order: []const usize) Allocator.Error!Rotation {
        var members = try alloc.alloc(Member, order.len);
        var filled: usize = 0;
        errdefer {
            for (members[0..filled]) |m| freeMember(alloc, m);
            alloc.free(members);
        }
        for (order, 0..) |roster_idx, i| {
            const src = roster[roster_idx];
            const avatar = try alloc.dupe(u8, src.avatar);
            errdefer alloc.free(avatar);
            const name = try alloc.dupe(u8, src.name);
            members[i] = .{ .avatar = avatar, .name = name };
            filled += 1;
        }
        return .{ .alloc = alloc, .members = members };
    }

    pub fn deinit(self: *Rotation) void {
        for (self.members) |m| freeMember(self.alloc, m);
        self.alloc.free(self.members);
        self.* = .{ .alloc = self.alloc };
    }

    fn freeMember(alloc: Allocator, m: Member) void {
        alloc.free(m.avatar);
        alloc.free(m.name);
    }

    /// The member whose turn is in flight. Survives stop() so the seal can still attribute.
    pub fn current(self: Rotation) ?Member {
        if (self.idx >= self.members.len) return null;
        return self.members[self.idx];
    }

    /// Move past the sealed member; the next one to launch, or null when the queue is done or
    /// was stopped.
    pub fn advance(self: *Rotation) ?Member {
        if (self.idx >= self.members.len) return null;
        self.idx += 1;
        if (self.stopped) return null;
        return self.current();
    }

    /// Abort the rotation: everyone still queued is dropped; the in-flight member seals as
    /// usual (advance() then returns null instead of launching them).
    pub fn stop(self: *Rotation) void {
        self.stopped = true;
    }

    pub fn remaining(self: Rotation) usize {
        if (self.stopped) return 0;
        return self.members.len - @min(self.idx, self.members.len);
    }
};

const testing = std.testing;

const rita = Member{ .avatar = "rita.png", .name = "Rita" };
const bram = Member{ .avatar = "bram.png", .name = "Bram Stoker" };
const echo = Member{ .avatar = "echo.png", .name = "Echo" };
const trio = [_]Member{ rita, bram, echo };

fn selectFree(alloc: Allocator, roster: []const Member, opts: SelectOpts) !void {
    const sel = try selectMembers(alloc, roster, opts);
    alloc.free(sel);
}

test "list_returns_every_enabled_member_in_list_order" {
    const sel = try selectMembers(testing.allocator, &trio, .{ .strategy = .list });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, sel);
}

test "list_dedupes_a_duplicated_avatar" {
    const dup = [_]Member{ rita, bram, rita };
    const sel = try selectMembers(testing.allocator, &dup, .{ .strategy = .list });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, sel);
}

test "manual_pick_overrides_every_strategy" {
    inline for (.{ ActivationStrategy.natural, .list, .manual, .pooled }) |s| {
        const sel = try selectMembers(testing.allocator, &trio, .{ .strategy = s, .manual_pick = 2 });
        defer testing.allocator.free(sel);
        try testing.expectEqualSlices(usize, &.{2}, sel);
    }
}

test "manual_pick_out_of_bounds_falls_through_to_the_strategy" {
    const sel = try selectMembers(testing.allocator, &trio, .{ .strategy = .list, .manual_pick = 99 });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, sel);
}

test "manual_strategy_activates_nobody_on_user_input" {
    const sel = try selectMembers(testing.allocator, &trio, .{ .strategy = .manual, .is_user_input = true });
    defer testing.allocator.free(sel);
    try testing.expectEqual(@as(usize, 0), sel.len);
}

test "manual_strategy_without_user_input_picks_the_first_member" {
    const sel = try selectMembers(testing.allocator, &trio, .{ .strategy = .manual, .is_user_input = false });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{0}, sel);
}

test "natural_activates_mentions_in_input_word_order" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .activation_text = "echo, then rita please",
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{ 2, 0 }, sel);
}

test "natural_matches_any_word_of_a_multiword_name_case_insensitively" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .activation_text = "what do you think, STOKER?",
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{1}, sel);
}

test "natural_never_matches_a_name_substring_that_is_not_a_whole_word" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .activation_text = "margarita time",
    });
    defer testing.allocator.free(sel);
    // No mention: falls back to the first member, not a substring hit on "Rita".
    try testing.expectEqualSlices(usize, &.{0}, sel);
}

test "natural_dedupes_a_double_mention" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .activation_text = "rita? rita!",
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{0}, sel);
}

test "natural_bans_the_last_speaker_from_a_non_user_trigger" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .activation_text = "rita and echo",
        .last = .{ .name = "Rita", .is_user = false },
        .is_user_input = false,
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{2}, sel);
}

test "allow_self_responses_lifts_the_last_speaker_ban" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .activation_text = "rita and echo",
        .last = .{ .name = "Rita", .is_user = false },
        .is_user_input = false,
        .allow_self_responses = true,
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, sel);
}

test "a_user_send_never_bans_the_last_speaker" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .activation_text = "rita",
        .last = .{ .name = "Rita", .is_user = false },
        .is_user_input = true,
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{0}, sel);
}

test "natural_with_no_mention_falls_back_to_the_first_eligible_member" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .activation_text = "carry on",
        .last = .{ .name = "Rita", .is_user = false },
        .is_user_input = false,
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{1}, sel);
}

test "an_all_banned_roster_still_answers" {
    const solo_roster = [_]Member{rita};
    const sel = try selectMembers(testing.allocator, &solo_roster, .{
        .activation_text = "go on",
        .last = .{ .name = "Rita", .is_user = false },
        .is_user_input = false,
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{0}, sel);
}

test "pooled_prefers_anyone_but_the_last_speaker" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .strategy = .pooled,
        .last = .{ .name = "Rita", .is_user = false },
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{1}, sel);
}

test "an_unknown_strategy_value_degrades_to_natural" {
    const sel = try selectMembers(testing.allocator, &trio, .{
        .strategy = @enumFromInt(7),
        .activation_text = "echo",
    });
    defer testing.allocator.free(sel);
    try testing.expectEqualSlices(usize, &.{2}, sel);
}

test "an_empty_roster_selects_nobody" {
    const sel = try selectMembers(testing.allocator, &.{}, .{ .strategy = .list });
    defer testing.allocator.free(sel);
    try testing.expectEqual(@as(usize, 0), sel.len);
}

test "selectMembers_cleans_up_on_every_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, selectFree, .{
        @as([]const Member, &trio),
        SelectOpts{ .activation_text = "rita and echo and bram" },
    });
}

test "selectMembers_never_panics_on_arbitrary_activation_text" {
    var prng = std.Random.DefaultPrng.init(0x6209);
    const rand = prng.random();
    var buf: [96]u8 = undefined;
    for (0..2000) |_| {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        const sel = try selectMembers(testing.allocator, &trio, .{
            .strategy = @enumFromInt(rand.int(u8)),
            .activation_text = buf[0..len],
            .is_user_input = rand.boolean(),
        });
        defer testing.allocator.free(sel);
        for (sel) |i| try testing.expect(i < trio.len);
    }
}

test "rotation_walks_the_exact_selected_sequence" {
    var rot = try Rotation.init(testing.allocator, &trio, &.{ 2, 0 });
    defer rot.deinit();
    try testing.expectEqualStrings("Echo", rot.current().?.name);
    try testing.expectEqual(@as(usize, 2), rot.remaining());
    const second = rot.advance().?;
    try testing.expectEqualStrings("Rita", second.name);
    try testing.expectEqualStrings("rita.png", second.avatar);
    try testing.expectEqual(@as(?Member, null), rot.advance());
    try testing.expectEqual(@as(usize, 0), rot.remaining());
}

test "stop_drops_the_queue_but_keeps_the_in_flight_member" {
    var rot = try Rotation.init(testing.allocator, &trio, &.{ 0, 1, 2 });
    defer rot.deinit();
    rot.stop();
    try testing.expectEqualStrings("Rita", rot.current().?.name);
    try testing.expectEqual(@as(?Member, null), rot.advance());
    try testing.expectEqual(@as(usize, 0), rot.remaining());
}

test "rotation_owns_dupes_that_survive_the_source_roster" {
    var mutable_avatar = "live.png".*;
    var mutable_name = "Live".*;
    const src = [_]Member{.{ .avatar = &mutable_avatar, .name = &mutable_name }};
    var rot = try Rotation.init(testing.allocator, &src, &.{0});
    defer rot.deinit();
    mutable_avatar[0] = 'X';
    mutable_name[0] = 'X';
    try testing.expectEqualStrings("live.png", rot.current().?.avatar);
    try testing.expectEqualStrings("Live", rot.current().?.name);
}

fn rotationInitFree(alloc: Allocator) !void {
    var rot = try Rotation.init(alloc, &trio, &.{ 0, 1, 2 });
    rot.deinit();
}

test "rotation_init_cleans_up_on_every_allocation_failure" {
    try testing.checkAllAllocationFailures(testing.allocator, rotationInitFree, .{});
}
