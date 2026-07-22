//! Diagnostic logging moved off the glue: the window error/rejection capture and the raw document
//! click telemetry stay JS listeners (both are irreducible browser-boundary hooks), but forward
//! their resolved strings here so the formatting and the std.log sink live Zig-side. The JS side is
//! a thin marshaller only.

const std = @import("std");

const ui_log = std.log.scoped(.ui);
const global_log = std.log.scoped(.global);

/// Build the CSS-selector label the glue used to format inline: `tag`, `#id` when present, then a
/// `.class` per whitespace-split token. Tag is lowercased to match the old `tagName.toLowerCase()`.
fn writeSelector(w: *std.Io.Writer, tag: []const u8, id: []const u8, class: []const u8) void {
    for (tag) |c| w.writeByte(std.ascii.toLower(c)) catch return;
    if (id.len > 0) w.print("#{s}", .{id}) catch return;
    var it = std.mem.tokenizeAny(u8, class, &std.ascii.whitespace);
    while (it.next()) |cls| w.print(".{s}", .{cls}) catch return;
}

/// A resolved control click, logged at ui:debug exactly as the old glue line did: `click <selector>
/// <label>`, where the glue resolved <label> (aria-label or trimmed text) DOM-side.
pub fn onClick(tag: []const u8, id: []const u8, class: []const u8, label: []const u8) void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeSelector(&w, tag, id, class);
    ui_log.debug("click {s} {s}", .{ w.buffered(), label });
}

/// An uncaught error or unhandled rejection, logged at global:err. `head` is the glue prefix
/// (`uncaught error:` / `unhandled rejection:`); `detail` is the Error stack, or the composed
/// message + filename:line:col when no Error object carried a stack. An empty detail logs head alone.
pub fn onUncaught(head: []const u8, detail: []const u8) void {
    if (detail.len > 0) global_log.err("{s} {s}", .{ head, detail }) else global_log.err("{s}", .{head});
}
