//! Pure model for the backgrounds panel: the /api/backgrounds/all contract, the two URL builders,
//! and the list mutations the panel drives (replace, remove, rename). No zx import, so the whole
//! module runs under `zig build test` (ZX5 split); the fetch, localStorage and DOM halves live in
//! backgrounds.zig and are browser-verified through the interaction gate.

const std = @import("std");
const data = @import("./char_data.zig");

const Allocator = std.mem.Allocator;

/// One image as /api/backgrounds/all returns it. The field names are camelCase because that is the
/// wire contract, not our convention.
///
/// `filename` stays typed. It comes off `fs.readdir` (util.js getImages), which cannot yield a
/// non-string, so its SHAPE is guaranteed at read time by the API that produces it, even though its
/// VALUE is whatever the user named the file. A parse only cares about shape, and a non-string
/// filename here would be a broken contract worth failing on. Tolerance would also be worse than
/// useless: an unreadable name reads as "", which `replace` drops, so the tile would vanish with
/// nothing said.
///
/// `isAnimated` gets no such guarantee, so it is read loosely. The server writes it as a real bool,
/// but it reads it back out of `.metadata.json` through `JSON.parse` with no validation and hands
/// the cached entry straight through (image-metadata.js:218); backgrounds.js:30 then defends only
/// the ABSENT case (`?? false`), not a wrong type. The shape therefore rests on a write that ran at
/// some point in the past into a mutable file that no read-time check covers. Typed `bool`, one odd
/// entry would fail the WHOLE array parse and the user would see ZERO backgrounds, for a decorative
/// badge.
pub const BackgroundJson = struct {
    filename: []const u8 = "",
    isAnimated: std.json.Value = .null,
};

/// The bool a loosely-typed JSON field carries; any other shape reads as false, which is the
/// server's own default for an entry it cannot find. Deliberately not char_data.favTruthy: that
/// reads every non-empty string as true, so a literal "false" would badge a still image animated.
pub fn jsonBool(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

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
            try next.append(alloc, .{ .filename = dup, .is_animated = jsonBool(img.isAnimated) });
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
    try testing.expect(!jsonBool(parsed.value.images[0].isAnimated));
    try testing.expectEqualStrings("b.webp", parsed.value.images[1].filename);
    try testing.expect(jsonBool(parsed.value.images[1].isAnimated));
}

test "one background with an odd isAnimated shape costs that badge, never the whole gallery" {
    // Typed `bool`, ONE of these failed the WHOLE array parse and the user saw ZERO backgrounds. The
    // odd entries sit BETWEEN good ones, so a parse that bails at the first bad field still fails.
    const body =
        \\{"images":[{"filename":"good.jpg","isAnimated":true},
        \\ {"filename":"str.webp","isAnimated":"true"},
        \\ {"filename":"null.png","isAnimated":null},
        \\ {"filename":"num.gif","isAnimated":1},
        \\ {"filename":"absent.jpg"},
        \\ {"filename":"tail.jpg","isAnimated":false}]}
    ;
    const parsed = try data.parseJson(AllResponse, testing.allocator, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 6), parsed.value.images.len);

    var list: List = .{};
    defer list.deinit(testing.allocator);
    try list.replace(testing.allocator, parsed.value.images);
    try testing.expectEqual(@as(usize, 6), list.slice().len);

    // The good entry keeps its badge; every shape the client cannot read reads as no claim at all.
    try testing.expect(list.slice()[0].is_animated);
    try testing.expect(!list.slice()[1].is_animated);
    try testing.expect(!list.slice()[2].is_animated);
    try testing.expect(!list.slice()[3].is_animated);
    try testing.expect(!list.slice()[4].is_animated);
    try testing.expect(!list.slice()[5].is_animated);

    // Every filename survives: the odd badge costs the badge and nothing else.
    try testing.expectEqualStrings("str.webp", list.slice()[1].filename);
    try testing.expectEqualStrings("tail.jpg", list.slice()[5].filename);
}

test "jsonBool reads only a real bool as a claim" {
    try testing.expect(jsonBool(.{ .bool = true }));
    try testing.expect(!jsonBool(.{ .bool = false }));
    try testing.expect(!jsonBool(.null));
    try testing.expect(!jsonBool(.{ .integer = 1 }));
    // favTruthy would read this as true; an animated flag spelled "false" must not badge.
    try testing.expect(!jsonBool(.{ .string = "false" }));
    try testing.expect(!jsonBool(.{ .string = "true" }));
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
        .{ .filename = "a.jpg", .isAnimated = .{ .bool = false } },
        .{ .filename = "", .isAnimated = .{ .bool = false } },
        .{ .filename = "b.jpg", .isAnimated = .{ .bool = true } },
    });
    try testing.expectEqual(@as(usize, 2), list.slice().len);
    try testing.expectEqualStrings("a.jpg", list.slice()[0].filename);
    try testing.expect(list.slice()[1].is_animated);

    // A second load replaces rather than appends.
    try list.replace(testing.allocator, &.{.{ .filename = "c.jpg", .isAnimated = .{ .bool = false } }});
    try testing.expectEqual(@as(usize, 1), list.slice().len);
    try testing.expectEqualStrings("c.jpg", list.slice()[0].filename);
}

test "indexOf finds an entry by exact filename only" {
    var list: List = .{};
    defer list.deinit(testing.allocator);
    try list.replace(testing.allocator, &.{
        .{ .filename = "a.jpg", .isAnimated = .{ .bool = false } },
        .{ .filename = "b.jpg", .isAnimated = .{ .bool = false } },
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
        .{ .filename = "a.jpg", .isAnimated = .{ .bool = false } },
        .{ .filename = "b.jpg", .isAnimated = .{ .bool = false } },
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
        .{ .filename = "a.jpg", .isAnimated = .{ .bool = false } },
        .{ .filename = "b.jpg", .isAnimated = .{ .bool = true } },
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
        .{ .filename = "a.jpg", .isAnimated = .{ .bool = false } },
        .{ .filename = "b.jpg", .isAnimated = .{ .bool = true } },
    });
    _ = try list.rename(alloc, "a.jpg", "c.jpg");
}

test "replacing the gallery cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, replaceAndFree, .{});
}
