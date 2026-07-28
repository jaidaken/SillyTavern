//! The two top-bar menus, arbitrated so only one is ever open.
//!
//! Both cards drop from the same corner and both are wider than the gap between their buttons, so
//! two open at once would sit on top of each other with the newer one stealing the older one's
//! clicks. Rather than nudging them apart and hoping the widths never change, opening either one
//! CLOSES the other: two menus on one bar behave like a menu bar, which is also what a user expects
//! from a pair of buttons this close together.
//!
//! This module exists to break the import cycle a direct fix would need. notify_bell_state and
//! sysmenu_state must not import each other, so the arbitration lives one level up, in the only
//! place that legitimately knows about both. The .zx handlers bind HERE instead of to the state
//! modules, which keeps each state module ignorant of the other's existence.

const zx = @import("zx");

const notify = @import("../notify/notify_bell_state.zig");
const sysmenu = @import("../nav/sysmenu_state.zig");

/// The bell was clicked: close the system card first, then let the bell toggle itself. Guarded on
/// "am I about to open", so a click that CLOSES the bell does not also disturb a card that a
/// mutually-exclusive bar cannot have open anyway.
///
/// closeIfOpen deliberately does NOT restore focus. The ordinary close path hands focus back to the
/// button that owns the card, which is right when the user dismissed it, but here the card is being
/// swapped for the other one: restoring focus would pull it off the button just clicked and onto the
/// other menu's button, and Escape would then miss the card it appears to be aimed at.
pub fn onBell(ev: zx.client.Event) void {
    if (!notify.isOpen()) sysmenu.closeIfOpen();
    notify.onToggle(ev);
}

/// The gear's twin of onBell.
pub fn onGear(ev: zx.client.Event) void {
    if (!sysmenu.isOpen()) notify.closeIfOpen();
    sysmenu.onGear(ev);
}

/// The system card's OTHER door: the command palette opens it without a gear click. It routes here
/// so the palette cannot leave both cards stacked on the same corner, which calling
/// sysmenu.setOpen directly did.
pub fn openSystem() void {
    notify.closeIfOpen();
    sysmenu.setOpen(true);
}
