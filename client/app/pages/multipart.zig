//! RFC 7578 multipart/form-data assembly for the Zig-owned uploads (C4). Pure bytes, no zx or DOM,
//! so it rides `zig build test`. Every upload in this app posts exactly ONE file part under the
//! single global multer field (`avatar`) plus zero or more text fields. The file bytes are copied in
//! verbatim, which is the property the byte-identical upload round-trip guards.

const std = @import("std");

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const File = struct {
    /// The multer field name; this app's global multer is `.single('avatar')`, so it is "avatar".
    field: []const u8,
    filename: []const u8,
    /// The picked File's MIME type, or "application/octet-stream" when the browser gave none.
    content_type: []const u8,
    bytes: []const u8,
};

pub const Error = error{ OutOfMemory, BoundaryUnresolvable };

const boundary_marker = "----ZxUploadBoundary";

/// A worst-case bound on the boundary length so callers can size a stack buffer.
pub const boundary_max = boundary_marker.len + 16;

var boundary_seq: u64 = 0;

/// The `Content-Type` request header value naming the boundary. Caller frees.
pub fn contentType(a: std.mem.Allocator, boundary: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary});
}

/// A boundary string absent from the file bytes, the filename, and every field value, so no payload
/// byte can be misread as a part delimiter. The 64-bit nonce makes a literal collision astronomical;
/// the scan makes correctness certain rather than probabilistic. Caller frees.
pub fn chooseBoundary(a: std.mem.Allocator, file: File, fields: []const Field) Error![]u8 {
    var attempt: usize = 0;
    while (attempt < 64) : (attempt += 1) {
        boundary_seq +%= 1;
        const b = try std.fmt.allocPrint(a, "{s}{x:0>16}", .{ boundary_marker, boundary_seq });
        if (!contains(file.bytes, b) and !contains(file.filename, b) and !fieldsContain(fields, b)) return b;
        a.free(b);
    }
    return Error.BoundaryUnresolvable;
}

/// Assemble the body. `boundary` must be absent from the file bytes and every field value; pass one
/// from chooseBoundary. Caller frees.
pub fn build(a: std.mem.Allocator, boundary: []const u8, file: File, fields: []const Field) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(a);

    try openPart(a, &body, boundary);
    try body.appendSlice(a, "Content-Disposition: form-data; name=\"");
    try body.appendSlice(a, file.field);
    try body.appendSlice(a, "\"; filename=\"");
    try appendQuoted(a, &body, file.filename);
    try body.appendSlice(a, "\"\r\n");
    try body.appendSlice(a, "Content-Type: ");
    try appendNoCrlf(a, &body, file.content_type);
    try body.appendSlice(a, "\r\n\r\n");
    try body.appendSlice(a, file.bytes);
    try body.appendSlice(a, "\r\n");

    for (fields) |f| {
        try openPart(a, &body, boundary);
        try body.appendSlice(a, "Content-Disposition: form-data; name=\"");
        try appendQuoted(a, &body, f.name);
        try body.appendSlice(a, "\"\r\n\r\n");
        try body.appendSlice(a, f.value);
        try body.appendSlice(a, "\r\n");
    }

    try body.appendSlice(a, "--");
    try body.appendSlice(a, boundary);
    try body.appendSlice(a, "--\r\n");
    return body.toOwnedSlice(a);
}

fn openPart(a: std.mem.Allocator, body: *std.ArrayList(u8), boundary: []const u8) !void {
    try body.appendSlice(a, "--");
    try body.appendSlice(a, boundary);
    try body.appendSlice(a, "\r\n");
}

/// RFC 7578: quote a name/filename by percent-escaping a literal quote and dropping CR/LF, so a
/// crafted filename cannot inject a header line.
fn appendQuoted(a: std.mem.Allocator, body: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try body.appendSlice(a, "%22"),
        '\r', '\n' => {},
        else => try body.append(a, c),
    };
}

/// Drop CR/LF from a header value so a crafted value cannot inject a header line. Unlike appendQuoted
/// it keeps quotes, since a Content-Type may legitimately carry a quoted charset parameter.
fn appendNoCrlf(a: std.mem.Allocator, body: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '\r', '\n' => {},
        else => try body.append(a, c),
    };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn fieldsContain(fields: []const Field, needle: []const u8) bool {
    for (fields) |f| {
        if (contains(f.name, needle) or contains(f.value, needle)) return true;
    }
    return false;
}

// ---- tests -------------------------------------------------------------------------------------

const t = std.testing;

/// Locate the first file part's payload in a built body: the bytes between the blank line ending the
/// part headers and the CRLF that precedes the next boundary. Mirrors what busboy parses.
fn extractFilePayload(body: []const u8, boundary: []const u8) ?[]const u8 {
    const headers_end = std.mem.indexOf(u8, body, "\r\n\r\n") orelse return null;
    const start = headers_end + 4;
    var delim_buf: [boundary_max + 4]u8 = undefined;
    const delim = std.fmt.bufPrint(&delim_buf, "\r\n--{s}", .{boundary}) catch return null;
    const rel_end = std.mem.indexOf(u8, body[start..], delim) orelse return null;
    return body[start .. start + rel_end];
}

test "build preserves file bytes verbatim including delimiter-shaped and non-utf8 content" {
    const a = t.allocator;
    // Bytes that would break a naive text encoder or a boundary scanner: a PNG magic prefix, a raw
    // CRLF, a fake boundary run, a NUL, and a high byte.
    const file_bytes = "\x89PNG\r\n\x1a\n\r\n------ZxUploadBoundary0000\x00\xff tail";
    const file = File{ .field = "avatar", .filename = "b g\".png", .content_type = "image/png", .bytes = file_bytes };
    const fields = [_]Field{.{ .name = "file_type", .value = "png" }};

    const boundary = try chooseBoundary(a, file, &fields);
    defer a.free(boundary);
    const body = try build(a, boundary, file, &fields);
    defer a.free(body);

    const payload = extractFilePayload(body, boundary) orelse return error.NoPayload;
    try t.expectEqualSlices(u8, file_bytes, payload);
}

test "build emits a wellformed part sequence and closing delimiter" {
    const a = t.allocator;
    const file = File{ .field = "avatar", .filename = "a.png", .content_type = "image/png", .bytes = "IMG" };
    const fields = [_]Field{ .{ .name = "file_type", .value = "png" }, .{ .name = "avatar_url", .value = "x.png" } };

    const boundary = try chooseBoundary(a, file, &fields);
    defer a.free(boundary);
    const body = try build(a, boundary, file, &fields);
    defer a.free(body);

    var open_buf: [boundary_max + 4]u8 = undefined;
    const open = try std.fmt.bufPrint(&open_buf, "--{s}\r\n", .{boundary});
    try t.expect(std.mem.startsWith(u8, body, open));

    var close_buf: [boundary_max + 8]u8 = undefined;
    const close = try std.fmt.bufPrint(&close_buf, "\r\n--{s}--\r\n", .{boundary});
    try t.expect(std.mem.endsWith(u8, body, close));

    try t.expect(contains(body, "name=\"avatar\"; filename=\"a.png\""));
    try t.expect(contains(body, "name=\"file_type\"\r\n\r\npng\r\n"));
    try t.expect(contains(body, "name=\"avatar_url\"\r\n\r\nx.png\r\n"));
    // Exactly three opening delimiters (two named text fields + one file) plus the closing one.
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, body, open));
}

test "build carries a non-ascii filename verbatim in the Content-Disposition" {
    const a = t.allocator;
    // Emoji + accented latin: the raw UTF-8 bytes must reach the part header untouched (the server
    // re-sanitizes the stored name, but the transport must not corrupt what it sends).
    const fname = "caf\u{00e9}\u{1f3a8}.png";
    const file = File{ .field = "avatar", .filename = fname, .content_type = "image/png", .bytes = "IMG" };
    const boundary = try chooseBoundary(a, file, &.{});
    defer a.free(boundary);
    const body = try build(a, boundary, file, &.{});
    defer a.free(body);

    const expect = "name=\"avatar\"; filename=\"" ++ fname ++ "\"";
    try t.expect(contains(body, expect));
}

test "chooseBoundary returns a delimiter that does not occur in the payload" {
    const a = t.allocator;
    // Force a collision on the first candidate by seeding the file bytes with it, then confirm the
    // returned boundary is genuinely absent from every scanned region.
    boundary_seq = 0;
    var probe_buf: [boundary_max]u8 = undefined;
    const first = try std.fmt.bufPrint(&probe_buf, "{s}{x:0>16}", .{ boundary_marker, @as(u64, 1) });
    const poisoned = try std.fmt.allocPrint(a, "lead {s} tail", .{first});
    defer a.free(poisoned);

    const file = File{ .field = "avatar", .filename = "n.bin", .content_type = "application/octet-stream", .bytes = poisoned };
    const fields = [_]Field{.{ .name = "k", .value = "v" }};
    const boundary = try chooseBoundary(a, file, &fields);
    defer a.free(boundary);

    try t.expect(!contains(poisoned, boundary));
    try t.expect(!std.mem.eql(u8, boundary, first));
}

test "build strips CR/LF from the content type so a crafted mime cannot inject a header" {
    const a = t.allocator;
    const file = File{ .field = "avatar", .filename = "a.png", .content_type = "image/png\r\nX-Injected: 1", .bytes = "IMG" };
    const boundary = try chooseBoundary(a, file, &.{});
    defer a.free(boundary);
    const body = try build(a, boundary, file, &.{});
    defer a.free(body);
    // The CRLF is gone, so the crafted value collapses into the mime value rather than a new header.
    try t.expect(!contains(body, "image/png\r\nX-Injected"));
    try t.expect(contains(body, "Content-Type: image/pngX-Injected: 1\r\n\r\n"));
}

test "appendQuoted escapes quotes and drops CR/LF" {
    const a = t.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try appendQuoted(a, &body, "a\"b\r\nc");
    try t.expectEqualStrings("a%22bc", body.items);
}

fn buildProbe(a: std.mem.Allocator) !void {
    const file = File{ .field = "avatar", .filename = "img.png", .content_type = "image/png", .bytes = "\x89PNG payload" };
    const fields = [_]Field{ .{ .name = "file_type", .value = "png" }, .{ .name = "avatar_url", .value = "u.png" } };
    const boundary = try chooseBoundary(a, file, &fields);
    defer a.free(boundary);
    const body = try build(a, boundary, file, &fields);
    a.free(body);
    const ctype = try contentType(a, boundary);
    a.free(ctype);
}

test "build and chooseBoundary release every allocation on injected failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildProbe, .{});
}
