//! The notification model: a bounded history plus the live-toast view over it, with no browser
//! dependency so it is provable by `zig build test`.
//!
//! Expiry is DRIVEN, not read from a clock: `tick(elapsed_ms)` subtracts from each live toast and a
//! toast dies at zero. The caller owns the cadence (notifications.zig runs one `setInterval`), so
//! there is no Date bridge across the wasm boundary and no per-toast timer to register, which the
//! 64-slot ziex callback registry could not have afforded anyway.
//!
//! A faded toast stays in history: fading is a `remaining_ms` transition, never a removal. History
//! drops an entry only when a push overflows `capacity` (oldest out) or `clear` empties it.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Notifications kept for review. A push past this evicts the oldest.
pub const capacity: usize = 50;

pub const Level = enum { info, success, warning, err };

pub const Notification = struct {
    id: u32,
    level: Level,
    /// Owned by the store; freed on eviction, `clear`, or `deinit`.
    text: []u8,
    /// Milliseconds of toast life left. Zero means faded: history-only from here on.
    remaining_ms: u32,
    read: bool,
    /// Epoch ms the caller stamped at push. OPAQUE here: the store never reads a clock and never
    /// interprets this, which is what keeps expiry deterministic. The drawer pairs it with a clock
    /// read of its own to phrase an age.
    created_ms: f64,
};

pub const Store = struct {
    allocator: Allocator,
    items: std.ArrayList(Notification) = .empty,
    next_id: u32 = 1,
    /// The live subset, rebuilt whenever it can have changed. A toast pushed earlier with a longer
    /// ttl outlives a later short one, so the live set is not a contiguous run of `items` and cannot
    /// be handed to the render as a sub-slice of it.
    toast_view: [capacity]Notification = undefined,
    toast_len: usize = 0,

    pub fn init(allocator: Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.items.items) |n| self.allocator.free(n.text);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Every notification held, oldest first.
    pub fn history(self: *const Store) []const Notification {
        return self.items.items;
    }

    /// The notifications still showing as toasts, oldest first.
    pub fn toasts(self: *const Store) []const Notification {
        return self.toast_view[0..self.toast_len];
    }

    pub fn unreadCount(self: *const Store) usize {
        var n: usize = 0;
        for (self.items.items) |item| {
            if (!item.read) n += 1;
        }
        return n;
    }

    pub fn markAllRead(self: *Store) void {
        for (self.items.items) |*item| item.read = true;
    }

    pub fn clear(self: *Store) void {
        for (self.items.items) |n| self.allocator.free(n.text);
        self.items.clearRetainingCapacity();
        self.toast_len = 0;
    }

    /// Record a notification and show it as a toast for `ttl_ms`. Returns its id.
    pub fn push(self: *Store, level: Level, text: []const u8, ttl_ms: u32, created_ms: f64) Allocator.Error!u32 {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        return self.pushOwned(level, owned, ttl_ms, created_ms);
    }

    /// `push` over a formatted message, without the intermediate copy `push` would take.
    pub fn pushFmt(
        self: *Store,
        level: Level,
        ttl_ms: u32,
        created_ms: f64,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!u32 {
        const owned = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(owned);
        return self.pushOwned(level, owned, ttl_ms, created_ms);
    }

    fn pushOwned(self: *Store, level: Level, owned: []u8, ttl_ms: u32, created_ms: f64) Allocator.Error!u32 {
        try self.items.ensureTotalCapacity(self.allocator, capacity);
        if (self.items.items.len >= capacity) {
            self.allocator.free(self.items.items[0].text);
            _ = self.items.orderedRemove(0);
        }
        const id = self.next_id;
        self.next_id +%= 1;
        self.items.appendAssumeCapacity(.{
            .id = id,
            .level = level,
            .text = owned,
            .remaining_ms = ttl_ms,
            .read = false,
            .created_ms = created_ms,
        });
        self.rebuildToasts();
        return id;
    }

    /// Age every live toast by `elapsed_ms`. True when at least one faded on this call, which is the
    /// only condition under which the toast overlay needs re-rendering.
    pub fn tick(self: *Store, elapsed_ms: u32) bool {
        var faded = false;
        for (self.items.items) |*n| {
            if (n.remaining_ms == 0) continue;
            n.remaining_ms -|= elapsed_ms;
            if (n.remaining_ms == 0) faded = true;
        }
        if (faded) self.rebuildToasts();
        return faded;
    }

    /// True while a toast is still showing, so the caller can idle its sweep timer.
    pub fn hasToasts(self: *const Store) bool {
        return self.toast_len > 0;
    }

    fn rebuildToasts(self: *Store) void {
        var n: usize = 0;
        for (self.items.items) |item| {
            if (item.remaining_ms == 0) continue;
            self.toast_view[n] = item;
            n += 1;
        }
        self.toast_len = n;
    }
};

test "push_records_the_text_and_hands_back_a_fresh_id" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const first = try store.push(.info, "saved", 3000, 0);
    const second = try store.push(.err, "backend offline", 6000, 0);

    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), store.history().len);
    try std.testing.expectEqualStrings("saved", store.history()[0].text);
    try std.testing.expectEqualStrings("backend offline", store.history()[1].text);
    try std.testing.expectEqual(Level.err, store.history()[1].level);
    try std.testing.expectEqual(@as(u32, 3000), store.history()[0].remaining_ms);
}

test "push_carries_the_caller_stamp_verbatim_and_the_sweep_never_ages_it" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.push(.info, "first", 1000, 1_700_000_000_000);
    _ = try store.pushFmt(.warning, 1000, 1_700_000_060_500, "n{d}", .{7});

    try std.testing.expectEqual(@as(f64, 1_700_000_000_000), store.history()[0].created_ms);
    try std.testing.expectEqual(@as(f64, 1_700_000_060_500), store.history()[1].created_ms);

    // The sweep ages remaining_ms and nothing else. If it touched the stamp, every entry's displayed
    // age would drift by however long its toast happened to be up.
    _ = store.tick(1000);
    try std.testing.expectEqual(@as(f64, 1_700_000_000_000), store.history()[0].created_ms);
    try std.testing.expectEqual(@as(u32, 0), store.history()[0].remaining_ms);
}

test "push_copies_the_caller_text_so_a_reused_buffer_cannot_rewrite_history" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    var scratch: [8]u8 = "alpha   ".*;
    _ = try store.push(.info, scratch[0..5], 1000, 0);
    @memcpy(scratch[0..5], "omega");

    try std.testing.expectEqualStrings("alpha", store.history()[0].text);
}

test "the_history_evicts_the_oldest_once_a_push_overflows_capacity" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const text = try std.fmt.bufPrint(&buf, "n{d}", .{i});
        _ = try store.push(.info, text, 1000, 0);
    }

    try std.testing.expectEqual(@as(usize, 50), capacity);
    try std.testing.expectEqual(capacity, store.history().len);
    try std.testing.expectEqualStrings("n10", store.history()[0].text);
    try std.testing.expectEqualStrings("n59", store.history()[capacity - 1].text);
}

test "tick_decrements_each_live_toast_and_fades_it_at_zero" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.push(.info, "saved", 1000, 0);

    try std.testing.expectEqual(false, store.tick(250));
    try std.testing.expectEqual(@as(u32, 750), store.history()[0].remaining_ms);
    try std.testing.expectEqual(@as(usize, 1), store.toasts().len);

    try std.testing.expectEqual(false, store.tick(250));
    try std.testing.expectEqual(false, store.tick(250));
    try std.testing.expectEqual(@as(u32, 250), store.history()[0].remaining_ms);

    try std.testing.expectEqual(true, store.tick(250));
    try std.testing.expectEqual(@as(usize, 0), store.toasts().len);
    try std.testing.expectEqual(@as(usize, 1), store.history().len);
    try std.testing.expectEqualStrings("saved", store.history()[0].text);
}

test "a_tick_wider_than_the_remaining_life_fades_the_toast_without_wrapping" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.push(.info, "saved", 100, 0);

    try std.testing.expectEqual(true, store.tick(5000));
    try std.testing.expectEqual(@as(u32, 0), store.history()[0].remaining_ms);
    try std.testing.expectEqual(@as(usize, 0), store.toasts().len);

    try std.testing.expectEqual(false, store.tick(5000));
}

test "a_long_lived_toast_outlives_a_shorter_one_pushed_after_it" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.push(.err, "backend offline", 4000, 0);
    _ = try store.push(.info, "saved", 500, 0);

    try std.testing.expectEqual(@as(usize, 2), store.toasts().len);
    try std.testing.expectEqual(true, store.tick(500));

    try std.testing.expectEqual(@as(usize, 1), store.toasts().len);
    try std.testing.expectEqualStrings("backend offline", store.toasts()[0].text);
    try std.testing.expectEqual(@as(usize, 2), store.history().len);
}

test "unread_count_rises_with_each_push_and_mark_all_read_clears_it" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.push(.info, "one", 1000, 0);
    _ = try store.push(.info, "two", 1000, 0);

    try std.testing.expectEqual(@as(usize, 2), store.unreadCount());
    store.markAllRead();
    try std.testing.expectEqual(@as(usize, 0), store.unreadCount());

    _ = try store.push(.warning, "three", 1000, 0);
    try std.testing.expectEqual(@as(usize, 1), store.unreadCount());
    try std.testing.expectEqual(true, store.history()[0].read);
    try std.testing.expectEqual(false, store.history()[2].read);
}

test "fading_a_toast_leaves_it_unread_so_the_badge_survives_the_fade" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.push(.info, "saved", 250, 0);

    try std.testing.expectEqual(true, store.tick(250));
    try std.testing.expectEqual(@as(usize, 1), store.unreadCount());
}

// hasToasts is what notifications.zig stops its sweep interval on, so a false stuck true is a 250ms
// wakeup that never ends, and a false stuck false retires the timer under a live toast.
test "has_toasts_goes_false_once_the_last_toast_fades_and_true_again_on_the_next_push" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectEqual(false, store.hasToasts());

    _ = try store.push(.info, "one", 500, 0);
    _ = try store.push(.info, "two", 250, 0);
    try std.testing.expectEqual(true, store.hasToasts());

    try std.testing.expectEqual(true, store.tick(250));
    try std.testing.expectEqual(true, store.hasToasts());
    try std.testing.expectEqual(@as(usize, 1), store.toasts().len);

    try std.testing.expectEqual(true, store.tick(250));
    try std.testing.expectEqual(false, store.hasToasts());

    _ = try store.push(.info, "three", 500, 0);
    try std.testing.expectEqual(true, store.hasToasts());
}

test "clear_empties_both_the_history_and_the_toasts" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.push(.info, "one", 1000, 0);
    _ = try store.push(.info, "two", 1000, 0);

    store.clear();
    try std.testing.expectEqual(@as(usize, 0), store.history().len);
    try std.testing.expectEqual(@as(usize, 0), store.toasts().len);
    try std.testing.expectEqual(@as(usize, 0), store.unreadCount());
    try std.testing.expectEqual(false, store.hasToasts());
}

test "push_fmt_formats_its_arguments_into_the_recorded_text" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.pushFmt(.err, 6000, 0, "upload failed: {s} ({d})", .{ "card.png", 413 });
    try std.testing.expectEqualStrings("upload failed: card.png (413)", store.history()[0].text);
    try std.testing.expectEqual(@as(u32, 6000), store.history()[0].remaining_ms);
}

fn pushAndDrain(allocator: Allocator) !void {
    var store = Store.init(allocator);
    defer store.deinit();

    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < capacity + 3) : (i += 1) {
        const text = try std.fmt.bufPrint(&buf, "n{d}", .{i});
        _ = try store.push(.info, text, 500, 0);
    }
    _ = try store.pushFmt(.warning, 500, 0, "n{d}", .{i});
    _ = store.tick(500);
}

test "pushing_past_capacity_cleans_up_on_every_allocation_failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pushAndDrain, .{});
}
