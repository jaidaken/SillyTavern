const std = @import("std");
const ui = @import("./ui.zig");

pub const MOTION_CLICK: u32 = 0;
pub const HYDRATED_FRAME: u32 = 1;

pub fn init() void {
    // Motion click is now handled by zieux component (SettingsBody.onMotionClick)
    // HYDRATED_FRAME is no longer needed - zieux handles hydration
}

fn motionCode(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "system")) return 0;
    if (std.mem.eql(u8, name, "on")) return 1;
    if (std.mem.eql(u8, name, "off")) return 2;
    return 0;
}

pub fn applyBootMotion() void {
    const stored = ui.getStoredMotion() orelse "system";
    ui.__st_set_motion(motionCode(stored));
}
