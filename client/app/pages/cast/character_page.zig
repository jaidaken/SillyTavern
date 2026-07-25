//! The character detail page's own state: the section catalogue that groups the card's fields, and
//! the one-section-at-a-time editing machine. card_editor.zig owns the card data, the fetch and the
//! save; this file owns which section (if any) is currently open for editing and what Save and Cancel
//! do to it. character_page_body.zx reads both and renders.
//!
//! WHY A SECTION TABLE: the flat editor showed every field at once. The page reads first: each card
//! field belongs to exactly one titled section, shown read-only until its Edit is clicked. The
//! grouping is DATA (the `sections` table), so a section is one row here and nothing in the markup,
//! and the comptime check below proves every editable field except `name` lands in exactly one
//! section (name is the header's own, edited through Rename, never a section).

const std = @import("std");
const card_editor = @import("./card_editor.zig");
const card_form = @import("./card_form.zig");
const char_store = @import("./character_store.zig");
const regions = @import("../shell/regions.zig");

const alloc = char_store.page_gpa;
const log = std.log.scoped(.charpage);

pub const Field = card_form.Field;

/// A section is either a set of card fields shown one control each, or the alternate-greetings list,
/// which has a SHAPE (add/remove) no field control covers.
pub const SectionKind = enum { fields, greetings };

/// The stable identity of a section: names its Edit/Save/Cancel controls (`data-section`) and keys
/// the editing state, so markup, dispatch and state all read one enum.
pub const SectionId = enum {
    first_message,
    description,
    personality,
    scenario,
    examples,
    greetings,
    tags,
    world,
    note,
    advanced,
    about,
};

pub const Section = struct {
    id: SectionId,
    /// The heading the section prints, and the read-first summary the row leads with.
    title: []const u8,
    kind: SectionKind = .fields,
    /// The card fields this section owns, in the order they show. Empty for the greetings section,
    /// which the body renders through card_editor's own greeting helpers instead.
    fields: []const Field = &.{},
};

/// The sections in render order (rework: read-first, one card concept per titled block). Every field
/// except `name` appears exactly once; the comptime check below fails the build if that ever drifts.
pub const sections = [_]Section{
    .{ .id = .first_message, .title = "First message", .fields = &.{.first_mes} },
    .{ .id = .description, .title = "Description", .fields = &.{.description} },
    .{ .id = .personality, .title = "Personality", .fields = &.{.personality} },
    .{ .id = .scenario, .title = "Scenario", .fields = &.{.scenario} },
    .{ .id = .examples, .title = "Example messages", .fields = &.{.mes_example} },
    .{ .id = .greetings, .title = "Alternate greetings", .kind = .greetings },
    .{ .id = .tags, .title = "Tags", .fields = &.{.tags} },
    .{ .id = .world, .title = "World info book", .fields = &.{.world} },
    .{ .id = .note, .title = "Character note", .fields = &.{ .depth_prompt_prompt, .depth_prompt_depth, .depth_prompt_role } },
    .{ .id = .advanced, .title = "Advanced", .fields = &.{ .system_prompt, .post_history_instructions } },
    .{ .id = .about, .title = "About", .fields = &.{ .creator, .creator_notes, .character_version } },
};

// Every editable field except `name` lands in exactly one section. A field added to card_form with no
// home here, or listed twice, would render nowhere or twice; this fails the build instead.
comptime {
    for (@typeInfo(Field).@"enum".fields) |f| {
        const id = @field(Field, f.name);
        if (id == .name) continue;
        var seen: usize = 0;
        for (sections) |s| {
            for (s.fields) |sf| {
                if (sf == id) seen += 1;
            }
        }
        if (seen != 1) @compileError("card field '" ++ f.name ++ "' must appear in exactly one character-page section");
    }
}

pub fn sectionFor(id: SectionId) ?Section {
    for (sections) |s| {
        if (s.id == id) return s;
    }
    return null;
}

/// The section's `data-section` key, and its inverse for the click dispatch. One-based on nothing:
/// the key is the tag name, which round-trips without a table.
pub fn sectionKey(id: SectionId) []const u8 {
    return @tagName(id);
}

pub fn sectionIdFromKey(key: []const u8) ?SectionId {
    inline for (@typeInfo(SectionId).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, key)) return @field(SectionId, f.name);
    }
    return null;
}

// ---- the editing machine (one section open at a time) ------------------------------------------

/// Which section is open for editing, or null when the page reads read-only. Paired with the avatar
/// it was opened on, so picking a different character while a section is open drops the stale edit
/// rather than editing the new card through the old section's buffers.
var editing: ?SectionId = null;
var editing_avatar: []u8 = &.{};

fn setEditingAvatar(av: []const u8) void {
    if (editing_avatar.len > 0) alloc.free(editing_avatar);
    editing_avatar = alloc.dupe(u8, av) catch &.{};
}

fn clearEditing() void {
    editing = null;
    if (editing_avatar.len > 0) alloc.free(editing_avatar);
    editing_avatar = &.{};
}

pub fn isEditing(id: SectionId) bool {
    return editing != null and editing.? == id;
}

pub fn anyEditing() bool {
    return editing != null;
}

/// Called by the body on every render: if the card on screen is no longer the one an edit was begun
/// on (the user picked another character while a section was open), drop the stale edit so the new
/// card reads read-first. Idempotent, so it is safe to call unconditionally each render.
pub fn syncTo(avatar: []const u8) void {
    if (editing == null) return;
    if (!std.mem.eql(u8, editing_avatar, avatar)) clearEditing();
}

/// Open a section for editing. One at a time: a click on another section's Edit while one is open is
/// ignored, so an unsaved edit is never silently dropped by switching. The body also disables the
/// other Edit controls while one is open, but this is the guard that actually enforces it.
pub fn beginEdit(id: SectionId) void {
    if (editing != null) return;
    setEditingAvatar(card_editor.editingAvatar());
    editing = id;
    log.debug("edit begin: {s}", .{@tagName(id)});
    regions.bumpShell();
}

/// Save the whole card (only the edited section's buffer differs from disk) and collapse back to the
/// read view. The save is async; the read view shows the edited buffer immediately, and the footer
/// notice reports the server's answer when it lands.
pub fn saveEdit() void {
    card_editor.save();
    clearEditing();
    regions.bumpShell();
}

/// Discard the section's edits back to the card as loaded, then collapse. A field section reverts
/// each field it owns; the greetings section reverts the whole list, shape included.
pub fn cancelEdit(id: SectionId) void {
    clearEditing();
    const sec = sectionFor(id) orelse {
        regions.bumpShell();
        return;
    };
    if (sec.kind == .greetings) {
        card_editor.revertGreetings();
    } else {
        for (sec.fields) |f| card_editor.revertField(f);
    }
    regions.bumpShell();
}
