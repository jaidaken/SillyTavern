//! What is left of the pre-ziex handler registry. The motion click is a zx handler now
//! (settings_body.zx -> ui.selectMotion), boot motion is read in bridge.bootInit off ui.storedMotion,
//! and hydration is the door's job, so the codes and the boot-motion helper are gone. Boot still
//! calls init() so the step stays visible in the log; the module goes with the D3 sweep.

const std = @import("std");

const log = std.log.scoped(.boot);

pub fn init() void {
    log.debug("handlers init", .{});
}
