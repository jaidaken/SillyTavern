//! Shared DOM-event helpers for zx handlers. ziex's body-delegated dispatch reports currentTarget
//! as the delegation root or null, never the bound element, and jsz property names are literal (no
//! dotted paths), so every handler resolves its element by walking target -> parents. One walk
//! lives here; a handler that writes its own is repeating the trap this module exists to bury.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const log = std.log.scoped(.ui);

/// event.target of a ctx.bind (stateful) handler, or null with a visible warn. The platform check
/// is comptime, so the .ref path is pruned from the server build.
pub fn statefulTarget(e: *zx.client.Event.Stateful) ?js.Object {
    if (zx.platform.role != .client) return null;
    return e.getEvent().ref.get(js.Object, "target") catch {
        log.warn("event carries no target", .{});
        return null;
    };
}

/// event.target of a plain handler, or null with a visible warn.
pub fn plainTarget(ev: zx.client.Event) ?js.Object {
    if (zx.platform.role != .client) return null;
    return ev.getEvent().ref.get(js.Object, "target") catch {
        log.warn("event carries no target", .{});
        return null;
    };
}

/// Walk start -> parents for a dataset key, returning the owned value (caller frees) or null.
pub fn datasetUp(start: js.Object, comptime key: []const u8) ?[]const u8 {
    if (zx.platform.role != .client) return null;
    var el: ?js.Object = start;
    while (el) |elem| {
        blk: {
            const ds = elem.get(js.Object, "dataset") catch break :blk;
            const val = ds.getAlloc(js.String, zx.allocator, key) catch break :blk;
            if (val.len > 0) return val;
            zx.allocator.free(val);
        }
        el = elem.get(js.Object, "parentElement") catch null;
    }
    return null;
}

/// True when `start` or any ancestor carries `id`. The membership test behind click-outside: the
/// panels (dock and drawer alike) render as #panel-view, so a click inside one is a click on the
/// panel however deep it landed.
pub fn hasAncestorId(start: js.Object, comptime id: []const u8) bool {
    if (zx.platform.role != .client) return false;
    var el: ?js.Object = start;
    while (el) |elem| {
        blk: {
            const value = elem.getAlloc(js.String, zx.allocator, "id") catch break :blk;
            defer zx.allocator.free(value);
            if (std.mem.eql(u8, value, id)) return true;
        }
        el = elem.get(js.Object, "parentElement") catch null;
    }
    return false;
}

/// True when `start` or any ancestor carries `class` among its class tokens. Token-wise, so
/// "drawers" never matches a "drawers-wide" that means something else.
pub fn hasAncestorClass(start: js.Object, comptime class: []const u8) bool {
    if (zx.platform.role != .client) return false;
    var el: ?js.Object = start;
    while (el) |elem| {
        blk: {
            const value = elem.getAlloc(js.String, zx.allocator, "className") catch break :blk;
            defer zx.allocator.free(value);
            var tokens = std.mem.tokenizeAny(u8, value, " \t\n");
            while (tokens.next()) |token| {
                if (std.mem.eql(u8, token, class)) return true;
            }
        }
        el = elem.get(js.Object, "parentElement") catch null;
    }
    return false;
}

/// document.getElementById via ziex's Document wrapper (the jsz-safe path; a hand-rolled
/// `get("getElementById")` + `call("")` always errors). Caller deinits the element.
pub fn elementById(allocator: std.mem.Allocator, id: []const u8) ?zx.client.Document.HTMLElement {
    if (zx.platform.role != .client) return null;
    var doc = zx.client.Document.init(allocator);
    defer doc.deinit();
    return doc.getElementById(id) catch null;
}

/// True when a keyboard event's key is Enter or Space (the WD37 activation pair for
/// role-carrying non-button controls). Frees the key it reads.
pub fn isActivationKey(e: *zx.client.Event.Stateful) bool {
    if (zx.platform.role != .client) return false;
    const key = e.key() orelse return false;
    defer zx.allocator.free(key);
    return std.mem.eql(u8, key, "Enter") or std.mem.eql(u8, key, " ");
}
