//! Pure model for the backgrounds panel: the /api/backgrounds/all contract, the two URL builders,
//! and the list mutations the panel drives (replace, remove, rename). No zx import, so the whole
//! module runs under `zig build test` (ZX5 split); the fetch, localStorage and DOM halves live in
//! backgrounds.zig and are browser-verified through the interaction gate.

const std = @import("std");
const data = @import("./char_data.zig");

const Allocator = std.mem.Allocator;

/// One image as /api/backgrounds/all returns it. The server reads isAnimated off its metadata
/// index; the field name is camelCase because that is the wire contract, not our convention.
pub const BackgroundJson = struct {
    filename: []const u8 = "",
    isAnimated: bool = false,
};

/// The /api/backgrounds/all response. Its `config` (the server's thumbnail dimensions) is ignored:
/// the gallery sizes its own tiles, so parsing it would pin a number we do not read.
pub const AllResponse = struct {
    images: []const BackgroundJson = &.{},
};

pub const Background = struct {
    filename: []u8,
    is_animated: bool,
};

/// `url("../backgrounds/<encoded>")` for the CSS layer, or `none` when nothing is chosen. The
/// filename is percent-encoded: a raw space ends the url() token early and the layer renders blank.
pub fn imageProp(alloc: Allocator, filename: []const u8) Allocator.Error![]u8 {
    if (filename.len == 0) return alloc.dupe(u8, "none");
    const enc = try data.encodeUriComponent(alloc, filename);
    defer alloc.free(enc);
    return std.fmt.allocPrint(alloc, "url(\"../backgrounds/{s}\")", .{enc});
}

/// The gallery tile's thumbnail. Routes through char_data.thumbUrl so the filename is encoded the
/// one way the whole client encodes them.
pub fn thumbUrl(alloc: Allocator, filename: []const u8) Allocator.Error![]u8 {
    return data.thumbUrl(alloc, "bg", filename);
}

/// The loaded gallery. Owns every filename it holds.
pub const List = struct {
    items: std.ArrayList(Background) = .empty,

    pub fn deinit(self: *List, alloc: Allocator) void {
        for (self.items.items) |b| alloc.free(b.filename);
        self.items.deinit(alloc);
        self.items = .empty;
    }

    pub fn slice(self: List) []const Background {
        return self.items.items;
    }

    /// Swap the whole gallery for a freshly fetched one. Built aside and committed at the end, so a
    /// failure part-way leaves the previous list intact rather than half-replaced.
    pub fn replace(self: *List, alloc: Allocator, images: []const BackgroundJson) Allocator.Error!void {
        var next: std.ArrayList(Background) = .empty;
        errdefer {
            for (next.items) |b| alloc.free(b.filename);
            next.deinit(alloc);
        }
        try next.ensureTotalCapacityPrecise(alloc, images.len);
        for (images) |img| {
            if (img.filename.len == 0) continue;
            const dup = try alloc.dupe(u8, img.filename);
            errdefer alloc.free(dup);
            try next.append(alloc, .{ .filename = dup, .is_animated = img.isAnimated });
        }
        self.deinit(alloc);
        self.items = next;
    }

    pub fn indexOf(self: List, filename: []const u8) ?usize {
        for (self.items.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.filename, filename)) return i;
        }
        return null;
    }

    pub fn remove(self: *List, alloc: Allocator, filename: []const u8) bool {
        const i = self.indexOf(filename) orelse return false;
        const gone = self.items.orderedRemove(i);
        alloc.free(gone.filename);
        return true;
    }

    /// Retitle one entry in place. The old name is freed only once the new one is allocated, so an
    /// OOM leaves the entry readable under its old name.
    pub fn rename(self: *List, alloc: Allocator, old: []const u8, new: []const u8) Allocator.Error!bool {
        const i = self.indexOf(old) orelse return false;
        const dup = try alloc.dupe(u8, new);
        alloc.free(self.items.items[i].filename);
        self.items.items[i].filename = dup;
        return true;
    }
};

const testing = std.testing;

test "imageProp encodes the filename into a url() token and yields none when unset" {
    const none = try imageProp(testing.allocator, "");
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("none", none);

    const spaced = try imageProp(testing.allocator, "a b.jpg");
    defer testing.allocator.free(spaced);
    try testing.expectEqualStrings("url(\"../backgrounds/a%20b.jpg\")", spaced);

    // A quote in a filename would otherwise close the url() string and inject CSS.
    const quoted = try imageProp(testing.allocator, "a\".jpg");
    defer testing.allocator.free(quoted);
    try testing.expectEqualStrings("url(\"../backgrounds/a%22.jpg\")", quoted);
}

test "thumbUrl builds the bg thumbnail path with the encoded file" {
    const out = try thumbUrl(testing.allocator, "moon lit.png");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("../thumbnail?type=bg&file=moon%20lit.png", out);
}

test "the all response parses the wire contract and tolerates its unread config" {
    const body =
        \\{"images":[{"filename":"a.jpg","isAnimated":false},{"filename":"b.webp","isAnimated":true}],
        \\ "config":{"width":160,"height":90}}
    ;
    const parsed = try data.parseJson(AllResponse, testing.allocator, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.images.len);
    try testing.expectEqualStrings("a.jpg", parsed.value.images[0].filename);
    try testing.expect(!parsed.value.images[0].isAnimated);
    try testing.expectEqualStrings("b.webp", parsed.value.images[1].filename);
    try testing.expect(parsed.value.images[1].isAnimated);
}

test "an empty or imageless response parses to an empty gallery" {
    const empty = try data.parseJson(AllResponse, testing.allocator, "{\"images\":[]}");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.value.images.len);

    const absent = try data.parseJson(AllResponse, testing.allocator, "{}");
    defer absent.deinit();
    try testing.expectEqual(@as(usize, 0), absent.value.images.len);
}

test "replace swaps the gallery and drops nameless entries" {
    var list: List = .{};
    defer list.deinit(testing.allocator);

    try list.replace(testing.allocator, &.{
        .{ .filename = "a.jpg", .isAnimated = false },
        .{ .filename = "", .isAnimated = false },
        .{ .filename = "b.jpg", .isAnimated = true },
    });
    try testing.expectEqual(@as(usize, 2), list.slice().len);
    try testing.expectEqualStrings("a.jpg", list.slice()[0].filename);
    try testing.expect(list.slice()[1].is_animated);

    // A second load replaces rather than appends.
    try list.replace(testing.allocator, &.{.{ .filename = "c.jpg", .isAnimated = false }});
    try testing.expectEqual(@as(usize, 1), list.slice().len);
    try testing.expectEqualStrings("c.jpg", list.slice()[0].filename);
}

test "indexOf finds an entry by exact filename only" {
    var list: List = .{};
    defer list.deinit(testing.allocator);
    try list.replace(testing.allocator, &.{
        .{ .filename = "a.jpg", .isAnimated = false },
        .{ .filename = "b.jpg", .isAnimated = false },
    });
    try testing.expectEqual(@as(?usize, 1), list.indexOf("b.jpg"));
    try testing.expectEqual(@as(?usize, null), list.indexOf("b"));
    try testing.expectEqual(@as(?usize, null), list.indexOf("B.jpg"));
    try testing.expectEqual(@as(?usize, null), list.indexOf(""));
}

test "remove drops the named entry and reports whether it was there" {
    var list: List = .{};
    defer list.deinit(testing.allocator);
    try list.replace(testing.allocator, &.{
        .{ .filename = "a.jpg", .isAnimated = false },
        .{ .filename = "b.jpg", .isAnimated = false },
    });
    try testing.expect(list.remove(testing.allocator, "a.jpg"));
    try testing.expectEqual(@as(usize, 1), list.slice().len);
    try testing.expectEqualStrings("b.jpg", list.slice()[0].filename);
    try testing.expect(!list.remove(testing.allocator, "a.jpg"));
}

test "rename retitles in place, keeps the order, and reports an unknown name" {
    var list: List = .{};
    defer list.deinit(testing.allocator);
    try list.replace(testing.allocator, &.{
        .{ .filename = "a.jpg", .isAnimated = false },
        .{ .filename = "b.jpg", .isAnimated = true },
    });
    try testing.expect(try list.rename(testing.allocator, "a.jpg", "moon lit.jpg"));
    try testing.expectEqualStrings("moon lit.jpg", list.slice()[0].filename);
    try testing.expect(list.slice()[1].is_animated);
    try testing.expectEqual(@as(?usize, 0), list.indexOf("moon lit.jpg"));
    try testing.expect(!try list.rename(testing.allocator, "gone.jpg", "x.jpg"));
}

fn replaceAndFree(alloc: Allocator) !void {
    var list: List = .{};
    defer list.deinit(alloc);
    try list.replace(alloc, &.{
        .{ .filename = "a.jpg", .isAnimated = false },
        .{ .filename = "b.jpg", .isAnimated = true },
    });
    _ = try list.rename(alloc, "a.jpg", "c.jpg");
}

test "replacing the gallery cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, replaceAndFree, .{});
}
