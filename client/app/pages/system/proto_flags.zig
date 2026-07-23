//! PHASE-0 PROTOTYPE, disposable. The screenshot flags, read once off location.search before the
//! first paint, so a still frame can reach a state that only a click or a hover would otherwise
//! open: ?showtabs pins both edge tabs, ?sysopen opens the system popover, ?openleft / ?openright
//! pre-open a dock.
//!
//! Shared by both new components, which is why it is its own file rather than a member of either.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const ui = @import("../nav/ui.zig");
const edgetabs_state = @import("../nav/edgetabs_state.zig");
const sysmenu_state = @import("../nav/sysmenu_state.zig");
const data = @import("../cast/char_data.zig");

const log = std.log.scoped(.panels);

var force_tabs: bool = false;
var read_once: bool = false;

/// True when ?showtabs pins both tabs visible. The reveal is a hover on the edge zone, which a
/// headless screenshot cannot perform, so this flag is how a still frame shows the tabs at all.
pub fn tabsForced() bool {
    return force_tabs;
}

/// Called from bridge.bootInit, ahead of the first paint.
pub fn boot() void {
    if (zx.platform.role != .client) return;
    if (read_once) return;
    read_once = true;
    const loc = js.global.get(js.Object, "location") catch return;
    defer loc.deinit();
    const search = loc.getAlloc(js.String, zx.allocator, "search") catch return;
    defer zx.allocator.free(search);
    force_tabs = data.hasQueryFlag(search, "showtabs");
    if (data.hasQueryFlag(search, "sysopen")) sysmenu_state.setOpen(true);
    if (data.hasQueryFlag(search, "openleft")) ui.openQuiet(edgetabs_state.left_panel);
    if (data.hasQueryFlag(search, "openright")) ui.openQuiet(edgetabs_state.right_panel);
    log.debug("proto flags: tabs={}", .{force_tabs});
}
