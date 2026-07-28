//! The system card's reactive half: whether the card is open, which of its three groups is showing,
//! and the click and key paths behind them. Sibling of sysmenu.zx; the catalogue and the storage
//! vocabulary are pure and live in sysmenu_model.zig, where `zig build test` proves them (ZX5).
//!
//! THE CONSTRAINT THIS FILE SERVES (rework section 4): every control the card reaches changes how
//! the app LOOKS, and a menu that covers the app hides the thing being judged. So the card stays a
//! small corner card, its body scrolls instead of growing, and a background, colour or motion change
//! applies to the visible page while the card is still open.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const ui = @import("./ui.zig");
const ui_state = @import("./ui_state.zig");
const model = @import("./sysmenu_model.zig");
const regions = @import("../shell/regions.zig");
const dom_event = @import("../platform/dom_event.zig");
const overlay_exit = @import("../platform/overlay_exit.zig");

const log = std.log.scoped(.panels);

pub const SysSection = model.SysSection;

/// The card's open/exit phase. `closing` keeps the card mounted through its `drawer-out` fade; the
/// timer below unmounts it. See overlay_exit.zig for the re-open guard.
var exit: overlay_exit.Exit = .{};

/// drawer-out is 200ms; unmount a hair later so the fade fully plays before the node leaves.
const close_ms: u32 = 220;

/// Null until the first read, which is what pulls the remembered section out of storage. Reading it
/// lazily keeps the restore out of the boot sequence: the card is a corner control most sessions
/// never touch, so it costs nothing until it is opened.
var current: ?SysSection = null;

pub fn isOpen() bool {
    return exit.isOpen();
}

/// Rendered while open OR fading out, so the `drawer-out` exit has a node to run on.
pub fn isMounted() bool {
    return exit.isMounted();
}

/// The card is on its way out: the markup swaps to the exit-animation class and drops its pointer events.
pub fn isClosing() bool {
    return exit.isClosing();
}

/// The group showing, restoring the remembered one on the first read. A missing or junk stored value
/// leaves the card on Look, the group its own form exists for.
pub fn section() SysSection {
    if (current) |s| return s;
    const s = storedSection() orelse model.default_section;
    current = s;
    return s;
}

/// aria-current for one switcher control (WD38): the state rides the attribute assistive tech reads,
/// so the markup computes no appearance of its own.
pub fn currentStr(id: SysSection) []const u8 {
    return if (section() == id) "true" else "false";
}

/// Boot-time open, with no rerender: the ?sysopen flag runs before the first paint. Also the
/// palette's open path (it opens the card then focuses the gear). Instant, no exit animation.
pub fn setOpen(v: bool) void {
    if (v) exit.open() else exit.closeInstant();
}

/// Close on behalf of the other top-bar menu (topbar_menus.zig). A no-op when already shut, so the
/// arbiter can call it unconditionally. Leaves focus ALONE: the card is being swapped for the bell's,
/// so pulling focus onto the gear would steal it from the button the user just pressed.
pub fn closeIfOpen() void {
    if (exit.isOpen()) closeCardInner(false);
}

pub fn onGear(_: zx.client.Event) void {
    if (exit.isOpen()) {
        closeCard();
        return;
    }
    exit.open();
    regions.bumpShell();
    // The bump rendered synchronously, so the target exists. Focus enters the card so Escape reaches
    // its handler (WD39).
    focusId("sys-popover");
}

pub fn onClose(_: zx.client.Event) void {
    closeCard();
}

/// Escape closes the card, matching the drawers' own dismissal. Bound on the card, which holds focus
/// while it is open; ziex dispatches from the event target upward, so a key pressed anywhere inside
/// the card reaches this. Guarded on `isOpen` so a key during the fade-out is ignored (the card is
/// already leaving).
pub fn onKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    if (!exit.isOpen()) return;
    const key = ev.key() orelse return;
    defer zx.allocator.free(key);
    if (!std.mem.eql(u8, key, "Escape")) return;
    ev.preventDefault();
    // STOPPED once consumed (the bell's rule): otherwise the same Escape reaches ui.onPageKey and
    // also tears down an open side dock under a card the user only meant to dismiss.
    ev.stopPropagation();
    closeCard();
}

/// Start the exit animation: keep the card mounted with its `drawer-out` class, move focus back to the
/// gear NOW (the closing card must not hold focus, WD39), and arm the unmount timer. A re-open before
/// it fires flips the phase back to open, so the timer becomes a no-op (overlay_exit.zig).
fn closeCard() void {
    closeCardInner(true);
}

/// `restore_focus` is false only for the arbiter's swap path, where another control is taking focus.
fn closeCardInner(restore_focus: bool) void {
    if (!exit.requestClose()) return;
    regions.bumpShell();
    if (restore_focus) focusId("sys-gear");
    if (zx.platform.role == .client) _ = zx.client.setTimeout(closeTick, close_ms);
}

/// The exit timer fired: unmount the card iff it is still closing.
fn closeTick() void {
    if (exit.timerFired()) regions.bumpShell();
}

/// A switcher click: show that group and remember it. The card does not close, so the swap reads as
/// navigation inside one surface, and the page behind it never flickers.
pub fn onSection(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return;
    defer target.deinit();
    const name = dom_event.datasetUp(target, "sysSection") orelse return;
    defer zx.allocator.free(name);
    const id = model.sectionFromStr(name) orelse {
        log.warn("unknown system section: {s}", .{name});
        return;
    };
    current = id;
    storeSection(id);
    regions.bumpShell();
}

/// A motion button. ui.selectMotion persists the pick and repaints the #shell class, so the change
/// lands on the visible app while the card stays open.
pub fn onMotion(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.plainTarget(ev) orelse return;
    defer target.deinit();
    const value = dom_event.datasetUp(target, "motionSet") orelse return;
    defer zx.allocator.free(value);
    const pref = ui_state.motionPrefFromStr(value) orelse return;
    ui.selectMotion(pref);
}

fn focusId(id: []const u8) void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(zx.allocator, id) orelse return;
    defer el.deinit();
    el.ref.call(void, "focus", .{}) catch {};
}

/// The remembered group, written on every switcher click (the ui.zig storeSection twin).
fn storeSection(id: SysSection) void {
    if (zx.platform.role != .client) return;
    const ls = js.global.get(js.Object, "localStorage") catch return;
    defer ls.deinit();
    ls.call(void, "setItem", .{ js.string(model.section_key), js.string(model.sectionTag(id)) }) catch {
        log.warn("localStorage write refused: {s}", .{model.section_key});
    };
}

fn storedSection() ?SysSection {
    if (zx.platform.role != .client) return null;
    const ls = js.global.get(js.Object, "localStorage") catch return null;
    defer ls.deinit();
    const raw = ls.callAlloc(?js.String, zx.allocator, "getItem", .{js.string(model.section_key)}) catch return null;
    const value = raw orelse return null;
    defer zx.allocator.free(value);
    return model.sectionFromStr(value);
}
