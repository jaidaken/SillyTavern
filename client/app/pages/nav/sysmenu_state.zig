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

const log = std.log.scoped(.panels);

pub const SysSection = model.SysSection;

var open: bool = false;

/// Null until the first read, which is what pulls the remembered section out of storage. Reading it
/// lazily keeps the restore out of the boot sequence: the card is a corner control most sessions
/// never touch, so it costs nothing until it is opened.
var current: ?SysSection = null;

pub fn isOpen() bool {
    return open;
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

/// Boot-time open, with no rerender: the ?sysopen flag runs before the first paint.
pub fn setOpen(v: bool) void {
    open = v;
}

/// The card's width and its margin from the screen edge, mirroring the `w-[21rem]` in sysmenu.zx.
/// The utility there has to stay a literal for the tailwind scanner to see it, so the two are paired
/// by this comment rather than by a shared token.
const card_width = "21rem";
const edge_gap = "0.75rem";

/// The gear and its card ride the same edge the left tab does, so an open Setup dock does not end up
/// with a floating button parked on top of its own controls.
///
/// CLAMPED, and it has to be: below 768px an open dock goes FULL-SCREEN while widthFor still reports
/// its desktop width, so the raw offset put the card 298px past the right edge of a 390px phone,
/// where it was invisible and unreachable. The ceiling is CSS rather than a measured viewport so it
/// re-evaluates on a window resize with no re-render, and clamp falls back to its floor when the
/// window is narrower than the card, which pins the card to the left edge instead of off-screen.
pub fn gearOffset(alloc: std.mem.Allocator) []const u8 {
    const dock: i64 = if (ui.openIdOn(.left) == null) 0 else @intFromFloat(ui.widthFor(.left));
    return std.fmt.allocPrint(
        alloc,
        "left:clamp({s}, {d}px, calc(100vw - {s} - {s}))",
        .{ edge_gap, dock + 12, card_width, edge_gap },
    ) catch "left:12px";
}

pub fn onGear(_: zx.client.Event) void {
    open = !open;
    regions.bumpShell();
    // The bump rendered synchronously, so the target exists. Focus enters the card so Escape reaches
    // its handler, and returns to the gear on close so the keyboard is not dropped (WD39).
    focusId(if (open) "sys-popover" else "sys-gear");
}

pub fn onClose(_: zx.client.Event) void {
    closeCard();
}

/// Escape closes the card, matching the drawers' own dismissal. Bound on the card, which holds focus
/// while it is open; ziex dispatches from the event target upward, so a key pressed anywhere inside
/// the card reaches this.
pub fn onKey(ev: zx.client.Event) void {
    if (zx.platform.role != .client) return;
    if (!open) return;
    const key = ev.key() orelse return;
    defer zx.allocator.free(key);
    if (!std.mem.eql(u8, key, "Escape")) return;
    ev.preventDefault();
    closeCard();
}

fn closeCard() void {
    open = false;
    regions.bumpShell();
    focusId("sys-gear");
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
