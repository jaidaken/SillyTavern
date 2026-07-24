//! C4 browser-forced transfer hub: the one path every Zig-owned multipart upload and blob download
//! runs through. A picked File and a Blob download cannot cross the wasm boundary as objects, so JS
//! keeps two thin shims (__st_read_file reads a file input to bytes; __st_download writes a blob and
//! clicks it). Everything else is Zig: this module reads the bytes back through the bridge, builds the
//! multipart body (multipart.zig) and posts it raw through net.zig, which owns csrf and the 403-retry.
//!
//! zx-importing, so it is browser-verified through the interaction gate (ZX5); multipart.zig is the
//! pure assembler it leans on and `zig build test` proves.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const net = @import("./net.zig");
const multipart = @import("./multipart.zig");
const char_store = @import("../cast/character_store.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.net);

/// A static multipart text field (name + value), re-exported so callers name their extra fields
/// without importing multipart directly.
pub const Field = multipart.Field;

/// Reported when an upload settles. `sent` is false ONLY for a cancelled picker (no file chosen),
/// which lets a caller tell "user cancelled" from "server refused" (both would read as status 0).
pub const OnDone = *const fn (status: u16, sent: bool) void;

/// The most extra text fields any endpoint posts (chat import: file_type, avatar_url, character_name,
/// user_name). The global multer field `avatar` carries the file and is not counted here.
const max_fields = 4;

/// One in-flight upload. Its address is the tag threaded through __st_read_file and net.requestRaw, so
/// the file-ready callback and the POST completion both find it. All slices are owned copies.
const Pending = struct {
    input_id: []u8 = &.{},
    url: []u8 = &.{},
    field_count: usize = 0,
    names: [max_fields][]u8 = undefined,
    values: [max_fields][]u8 = undefined,
    add_file_type: bool = false,
    on_done: OnDone,
};

/// One upload's parameters. `fields` are the static text fields known at pick time; `add_file_type`
/// appends a `file_type` field carrying the picked file's lowercased extension, whose value is only
/// known once the file is read, so it is derived in fileReady rather than passed here.
pub const Spec = struct {
    input_id: []const u8,
    url: []const u8,
    fields: []const multipart.Field = &.{},
    add_file_type: bool = false,
    on_done: OnDone,
};

/// Begin an upload: dupe the endpoint and fields, then ask JS to read the picked file to bytes. The
/// bytes arrive later through fileReady. A missing helper or OOM reports failure at once.
pub fn start(spec: Spec) void {
    if (zx.platform.role != .client) return;
    if (spec.fields.len + @intFromBool(spec.add_file_type) > max_fields) {
        log.err("upload has too many fields for the {d} cap: {s}", .{ max_fields, spec.url });
        spec.on_done(0, false);
        return;
    }
    const p = alloc.create(Pending) catch {
        spec.on_done(0, false);
        return;
    };
    p.* = .{ .on_done = spec.on_done, .add_file_type = spec.add_file_type };
    p.input_id = alloc.dupe(u8, spec.input_id) catch return abort(p, spec.on_done);
    p.url = alloc.dupe(u8, spec.url) catch return abort(p, spec.on_done);
    for (spec.fields) |f| {
        const i = p.field_count;
        const n = alloc.dupe(u8, f.name) catch return abort(p, spec.on_done);
        const v = alloc.dupe(u8, f.value) catch {
            alloc.free(n);
            return abort(p, spec.on_done);
        };
        p.names[i] = n;
        p.values[i] = v;
        p.field_count = i + 1;
    }
    js.global.call(void, "__st_read_file", .{ js.string(spec.input_id), @as(usize, @intFromPtr(p)) }) catch {
        log.warn("upload read-file helper missing", .{});
        destroy(p);
        spec.on_done(0, false);
    };
}

fn abort(p: *Pending, on_done: OnDone) void {
    destroy(p);
    on_done(0, false);
}

/// Called from the bridge once JS has read the file to bytes (or with an empty file for a cancelled
/// picker). The three slices were allocated by the JS door and are owned here; they are copied into
/// the multipart body, so they are freed on every path out.
pub fn fileReady(tag: usize, bytes: []u8, filename: []u8, mime: []u8) void {
    const p: *Pending = @ptrFromInt(tag);
    defer freeDoorBufs(bytes, filename, mime);

    if (bytes.len == 0) {
        const on_done = p.on_done;
        destroy(p);
        on_done(0, false);
        return;
    }

    const file = multipart.File{
        .field = "avatar",
        .filename = filename,
        .content_type = if (mime.len > 0) mime else "application/octet-stream",
        .bytes = bytes,
    };
    var fbuf: [max_fields]multipart.Field = undefined;
    var fcount: usize = 0;
    for (0..p.field_count) |i| {
        fbuf[fcount] = .{ .name = p.names[i], .value = p.values[i] };
        fcount += 1;
    }
    var ext_buf: [16]u8 = undefined;
    if (p.add_file_type and fcount < max_fields) {
        fbuf[fcount] = .{ .name = "file_type", .value = fileExt(&ext_buf, filename) };
        fcount += 1;
    }
    const fields = fbuf[0..fcount];

    const boundary = multipart.chooseBoundary(alloc, file, fields) catch return fail(p);
    defer alloc.free(boundary);
    const body = multipart.build(alloc, boundary, file, fields) catch return fail(p);
    defer alloc.free(body);
    const ctype = multipart.contentType(alloc, boundary) catch return fail(p);
    defer alloc.free(ctype);

    net.requestRaw(p.url, ctype, body, @intFromPtr(p), onPosted, .{});
}

fn onPosted(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = res;
    const p: *Pending = @ptrFromInt(@as(usize, @intCast(tag)));
    const on_done = p.on_done;
    destroy(p);
    on_done(status, true);
}

/// A file was chosen but the client could not build or post it (OOM): report a failed send.
fn fail(p: *Pending) void {
    const on_done = p.on_done;
    destroy(p);
    on_done(0, true);
}

fn destroy(p: *Pending) void {
    if (p.input_id.len > 0) alloc.free(p.input_id);
    if (p.url.len > 0) alloc.free(p.url);
    for (0..p.field_count) |i| {
        alloc.free(p.names[i]);
        alloc.free(p.values[i]);
    }
    alloc.destroy(p);
}

fn freeDoorBufs(bytes: []u8, filename: []u8, mime: []u8) void {
    if (bytes.len > 0) alloc.free(bytes);
    if (filename.len > 0) alloc.free(filename);
    if (mime.len > 0) alloc.free(mime);
}

/// The lowercased extension after the last dot (no dot -> ""), written into `buf`. Matches the old
/// glue's `file.name.split('.').pop().toLowerCase()`.
fn fileExt(buf: []u8, filename: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return "";
    const raw = filename[dot + 1 ..];
    const n = @min(raw.len, buf.len);
    for (0..n) |i| buf[i] = std.ascii.toLower(raw[i]);
    return buf[0..n];
}

/// One in-flight export whose whole response body IS the file. Its address is the tag; the filename
/// and mime ride it because net's callback carries only that tag.
const Download = struct {
    filename: []u8,
    mime: []u8,
};

/// Fetch a file and download the whole response verbatim (the character PNG and the lorebook JSON).
/// `raw` uses the binary-safe door op (a PNG response); the JSON path otherwise. A caller that must
/// reshape the response first (chat export pulls `.result`) downloads itself via download() instead.
pub fn requestDownload(url: []const u8, content_type: []const u8, body: []const u8, filename: []const u8, mime: []const u8, raw: bool) void {
    if (zx.platform.role != .client) return;
    const d = alloc.create(Download) catch return;
    const fn_c = alloc.dupe(u8, filename) catch {
        alloc.destroy(d);
        return;
    };
    const mime_c = alloc.dupe(u8, mime) catch {
        alloc.free(fn_c);
        alloc.destroy(d);
        return;
    };
    d.* = .{ .filename = fn_c, .mime = mime_c };
    const tag = @intFromPtr(d);
    if (raw) net.requestRaw(url, content_type, body, tag, onDownloadFetched, .{}) else net.request(url, body, tag, onDownloadFetched, .{});
}

fn onDownloadFetched(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    const d: *Download = @ptrFromInt(@as(usize, @intCast(tag)));
    defer {
        alloc.free(d.filename);
        alloc.free(d.mime);
        alloc.destroy(d);
    }
    if (res == null or status < 200 or status >= 300) {
        log.warn("download fetch failed ({d}): {s}", .{ status, d.filename });
        return;
    }
    const bytes = res.?.text() catch return;
    download(d.filename, bytes, d.mime);
}

/// Hand a fetched blob to the browser to download. objectURL + a.click is the one browser primitive
/// with no wasm path, so `bytes` (living in wasm memory) are passed by pointer for JS to copy into a
/// Blob synchronously, before the caller frees the response.
pub fn download(name: []const u8, bytes: []const u8, mime: []const u8) void {
    if (zx.platform.role != .client) return;
    if (bytes.len == 0) return;
    js.global.call(void, "__st_download", .{
        js.string(name),
        @as(usize, @intFromPtr(bytes.ptr)),
        bytes.len,
        js.string(mime),
    }) catch {
        log.warn("download helper missing", .{});
    };
}
