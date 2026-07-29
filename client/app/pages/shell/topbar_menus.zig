//! The three top-bar menus, arbitrated so only one is ever open.
//!
//! All three cards drop from the same corner and each is wider than the gap between their buttons, so
//! two open at once would sit on top of each other with the newer one stealing the older one's
//! clicks. Rather than nudging them apart and hoping the widths never change, opening any one CLOSES
//! the others: three menus on one bar behave like a menu bar, which is also what a user expects from
//! buttons this close together.
//!
//! This module exists to break the import cycle a direct fix would need. The three state modules must
//! not import each other, so the arbitration lives one level up, in the only place that legitimately
//! knows about all of them. The .zx handlers bind HERE instead of to the state modules, which keeps
//! each state module ignorant of the other two.

const zx = @import("zx");

const ui = @import("../nav/ui.zig");
const notify = @import("../notify/notify_bell_state.zig");
const sysmenu = @import("../nav/sysmenu_state.zig");
const conn_menu = @import("../setup/conn_menu_state.zig");

/// The bell was clicked: close the other two cards first, then let the bell toggle itself. Guarded on
/// "am I about to open", so a click that CLOSES the bell does not also disturb cards that a
/// mutually-exclusive bar cannot have open anyway.
///
/// closeIfOpen deliberately does NOT restore focus. The ordinary close path hands focus back to the
/// button that owns the card, which is right when the user dismissed it, but here the card is being
/// swapped for another: restoring focus would pull it off the button just clicked and onto the other
/// menu's button, and Escape would then miss the card it appears to be aimed at.
pub fn onBell(ev: zx.client.Event) void {
    if (!notify.isOpen()) closeOthers(.bell);
    notify.onToggle(ev);
}

/// The gear's twin of onBell.
pub fn onGear(ev: zx.client.Event) void {
    if (!sysmenu.isOpen()) closeOthers(.gear);
    sysmenu.onGear(ev);
}

/// The status chip's twin of onBell, plus the one thing the other two never have to do: SHUT A DOCK.
/// The card and the Setup dock's API section render the same body, and connections_body.zx names its
/// fields with element ids that connection.zig looks up (#llama-url, #conn-api-key, #conn-status).
/// Mounted twice, Connect would read the dock's URL box and write its progress into the dock's status
/// line, behind the card being read. Only a dock actually SHOWING API is closed; one showing AI,
/// Format or World is left alone, because it carries none of those ids.
pub fn onChip(ev: zx.client.Event) void {
    if (!conn_menu.isOpen()) {
        closeOthers(.chip);
        if (ui.openIdOn(.left) == .connections) ui.closeSide(.left);
    }
    conn_menu.onToggle(ev);
}

/// The system card's OTHER door: the command palette opens it without a gear click. It routes here so
/// the palette cannot leave two cards stacked on the same corner, which calling sysmenu.setOpen
/// directly did.
pub fn openSystem() void {
    closeOthers(.gear);
    sysmenu.setOpen(true);
}

const Menu = enum { bell, gear, chip };

/// Shut every card but the one taking over. Each closeIfOpen is a no-op when that card is already
/// shut, so the caller states its own identity and nothing else.
fn closeOthers(keep: Menu) void {
    if (keep != .bell) notify.closeIfOpen();
    if (keep != .gear) sysmenu.closeIfOpen();
    if (keep != .chip) conn_menu.closeIfOpen();
}
