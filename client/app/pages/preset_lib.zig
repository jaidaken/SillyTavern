//! The pure half of the instruct/context preset library: reading a preset array out of a settings
//! RESPONSE, and composing the two JSON documents a pick and a save produce. No zx import, so
//! `zig build test` proves the whole model natively (ZX5); the arena, the fetch and the rerender
//! wrappers live in template_presets.zig and are browser-verified.
//!
//! The split is not bookkeeping. Every rule below is a pure function of an input that can be written
//! down, and the two that matter most fail SILENTLY in a browser: a preset that omits `enabled`
//! unwraps the prompt, and a preset that predates the anchors kills the author's note. Neither
//! prints anything. A browser row proving them has to drive a panel, send a message and read a
//! recorded prompt, and it can go green for reasons that have nothing to do with the rule (a race on
//! a lazy fetch, a stale DOM property, a selector that never matched). A native test over these
//! functions cannot do any of that.

const std = @import("std");

const templates = @import("./templates.zig");
const nav = @import("./dropdown_nav.zig");

const Allocator = std.mem.Allocator;

/// Which preset family. The tag names ARE the wire values: they are the `apiId` /api/presets/save
/// switches on (presets.js:29-32) and the response keys the arrays arrive under.
pub const Kind = enum { instruct, context };

/// One preset as its file carries it: the display name, and the whole object it came from. The
/// object is kept rather than parsed into a struct because the apply overlays it field by field, and
/// because a field this client does not model (`activation_regex`, `single_line`) must survive a
/// pick.
pub const Preset = struct {
    name: []const u8,
    value: std.json.Value,
};

/// Every nameable object in one preset array, in file order.
///
/// TOLERANCE, and it is the whole reason this walks std.json.Value instead of parsing a typed array:
/// these files are USER-WRITABLE, other tools write them, and the server validates only that a file
/// is parseable JSON, never its shape (settings.js:55-71 JSON.parses each file and skips only the
/// ones that throw). A typed parse fails the WHOLE array on ONE odd field, which is the bug that
/// emptied three lists on this project already.
///
/// So each element is judged alone: a non-object, or one with no usable string name, is SKIPPED. A
/// preset nobody can name is a preset nobody can pick, and it must not cost the ones beside it. A
/// hostile FIELD costs nothing here at all, because the object is carried whole and judged only when
/// it is applied.
pub fn collect(a: Allocator, root_obj: std.json.ObjectMap, key: []const u8) Allocator.Error![]const Preset {
    const v = root_obj.get(key) orelse return &.{};
    const arr = switch (v) {
        .array => |x| x,
        else => return &.{},
    };
    var out: std.ArrayList(Preset) = .empty;
    errdefer out.deinit(a);
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (o.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (name.len == 0) continue;
        try out.append(a, .{ .name = name, .value = item });
    }
    return out.toOwnedSlice(a);
}

/// Dropdown options over a preset list. The name is both the value and the label: it is what the
/// file calls itself and what the user picks by.
pub fn buildOptions(a: Allocator, list: []const Preset) Allocator.Error![]const nav.Option {
    const out = try a.alloc(nav.Option, list.len);
    for (list, 0..) |p, i| out[i] = .{ .value = p.name, .label = p.name };
    return out;
}

pub fn find(list: []const Preset, name: []const u8) ?Preset {
    for (list) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// `live` as a settings blob, with `kind`'s half OVERLAID by the preset's own fields. Feeding the
/// result to the same parse the boot settings load uses is what makes a pick and a reload agree.
///
/// OVERLAID, not replaced, and that is the classic client's rule rather than a convenience: its apply
/// loop is `if (preset[control.property] !== undefined)` (instruct-mode.js:839, power-user.js:2038),
/// so a field the preset omits KEEPS its live value. It matters immediately: NO shipped instruct
/// preset carries `enabled` (it is a user toggle living in power_user.instruct, not a template
/// property), so a wholesale replace would read the struct default and picking "ChatML" would
/// silently switch instruct wrapping OFF, giving the user LESS templating than before they picked a
/// template.
///
/// THE ANCHOR MARKER TRAVELS WITH THE STORY STRING IT DESCRIBES. mergeTemplates always stamps
/// `story_string_position` on the live half (our own saves are already migrated), so under the
/// overlay a context preset that PREDATES the anchors would inherit that stamp, skip the migration
/// parseContext runs, and never gain its anchorBefore/anchorAfter slots. An author's note at either
/// anchor would then render NOWHERE, silently, having worked a moment earlier. Dropping the
/// inherited stamp is what the classic client does by calling autoFixStoryString on the PRESET,
/// whose own marker decides (power-user.js:1937, :2032).
pub fn blobWith(a: Allocator, kind: Kind, preset: std.json.Value, live: templates.Templates) ![]u8 {
    const src = switch (preset) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    var root = std.json.Value{ .object = .empty };
    try templates.mergeTemplates(a, &root.object, live);
    var power_user = root.object.get("power_user").?.object;

    var half = try overlay(a, power_user.get(@tagName(kind)).?.object, src);

    // A preset with no marker of its own must not inherit the live half's: see the anchor paragraph
    // above. This line is what keeps a picked preset from silently killing the author's note.
    if (kind == .context and src.get("story_string_position") == null) {
        _ = half.orderedRemove("story_string_position");
    }

    try power_user.put(a, @tagName(kind), .{ .object = half });
    try root.object.put(a, "power_user", .{ .object = power_user });
    return std.json.Stringify.valueAlloc(a, root, .{});
}

/// `base` with every key of `over` written on top. Copied rather than mutated in place: `base` and
/// `over` are borrowed from arenas the caller owns, and writing into either would corrupt the stored
/// preset the next pick reads.
fn overlay(a: Allocator, base: std.json.ObjectMap, over: std.json.ObjectMap) Allocator.Error!std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    var base_it = base.iterator();
    while (base_it.next()) |e| try out.put(a, e.key_ptr.*, e.value_ptr.*);
    var over_it = over.iterator();
    while (over_it.next()) |e| try out.put(a, e.key_ptr.*, e.value_ptr.*);
    return out;
}

/// Keys that must never reach a saved preset file, whichever half wrote them.
///
/// `enabled` is INSTRUCT MODE ITSELF, not a template property. The classic client deletes it from
/// every preset it writes (the filteredKeys loop at preset-manager.js:732 runs for EVERY apiId, and
/// :693 lists the key), and none of the 38 shipped instruct presets carries it. It must not ride our
/// save either, and the reason is blobWith's overlay rule above: a preset that DOES carry
/// `enabled: false` switches instruct OFF for whoever picks it. That is the silent failure this
/// module's header opens with, and our save is the only thing in the ecosystem that could manufacture
/// a file which causes it. Stripping it costs the saver nothing: a preset that omits the key keeps
/// the picker's live value, which is already their own.
///
/// `preset` names the file rather than describing a template, and the classic client reads
/// `power_user.instruct.preset` as the selected-preset name (preset-manager.js:658), so one riding a
/// picked file would fight the blob's own record of what is selected. No shipped preset carries it,
/// but a base is somebody else's file: hand-editable, and the clone below keeps every key on purpose.
///
/// THE SAMPLER FAMILY'S FIVE KEYS ARE DELIBERATELY NOT HERE (sampler_presets.forbidden_keys). Four of
/// them name a HOST, which that family must guard because `textgenerationwebui_settings` is both the
/// sampler store AND the backend connection, so its classic-side save filters 50 keys out of a live
/// object that really does hold a server URL. `power_user.instruct`/`power_user.context` have never
/// held a connection in any client, and our base is a preset FILE rather than a live blob, so there is
/// no path that puts a host in one. Guarding against a key no code has ever written there would be
/// mirroring the sibling's shape past the reason for it.
const forbidden_keys = [_][]const u8{ "enabled", "preset" };

/// The /api/presets/save body: `{ name, preset, apiId }`, the three keys the route reads. It 400s
/// without `preset` or `name` (presets.js:44-47) and `apiId` picks the directory it writes to, so
/// the field names ARE the contract.
///
/// `base` is the preset the live half CAME FROM, and saving copies it and overwrites only the fields
/// this client models. Without it a save writes the modelled fields ALONE, which silently deletes
/// every field we do not model: 7 in all 38 shipped instruct presets, 7 more in all 34 context ones,
/// so a saved CONTEXT preset kept 5 of its 12 fields.
///
/// WHICH OF THOSE 14 ACTUALLY BITE, enumerated over the shipped files rather than reasoned about
/// (the values matter, not just the key names, because a dropped key is read back as `undefined` and
/// the classic client's apply loop then KEEPS ITS LIVE VALUE rather than taking the file's):
/// `sequences_as_stop_strings` is true in 37/38 instruct presets, `story_string_depth` is 1 in 34/34
/// context presets, `names_as_stop_strings` true in 34/34, `always_force_name2` true in 32/34, and
/// `user_alignment_message` carries real prose in 5/38. Those are the ones a round trip through this
/// client silently reverted. The rest (`activation_regex`, `skip_examples`, `first_input_sequence`,
/// `last_input_sequence`, `last_system_sequence`, `story_string_role`, `trim_sentences`,
/// `use_stop_strings`, `single_line`) are at their type default in every shipped file bar one, so
/// dropping them cost the key and almost never the behavior. The fix covers all 14 by construction,
/// which is the point of copying the base rather than listing what to copy.
///
/// The classic client keeps them by cloning the live object it applied the preset into
/// (preset-manager.js:657); we keep them by cloning the file itself, the same object one step earlier.
///
/// No base (the live templates match no preset we hold, so they were hand-edited or came from a name
/// we cannot find) -> the modelled fields alone, exactly as before. There is no source object to
/// preserve from, and inventing one would write another preset's fields into this one.
pub fn saveBody(a: Allocator, kind: Kind, name: []const u8, base: ?std.json.ObjectMap, live: templates.Templates) Allocator.Error![]u8 {
    var root = std.json.Value{ .object = .empty };
    try templates.mergeTemplates(a, &root.object, live);
    const power_user = root.object.get("power_user").?.object;

    // The panel's values win over the base's; the base keeps every field the panel never modelled.
    var preset = try overlay(a, base orelse .empty, power_user.get(@tagName(kind)).?.object);
    // AFTER the overlay, not before: `enabled` is stamped by the modelled half, so a base-only strip
    // would put it straight back.
    for (forbidden_keys) |k| _ = preset.orderedRemove(k);
    try preset.put(a, "name", .{ .string = name });

    var body: std.json.ObjectMap = .empty;
    try body.put(a, "name", .{ .string = name });
    try body.put(a, "preset", .{ .object = preset });
    try body.put(a, "apiId", .{ .string = @tagName(kind) });
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = body }, .{});
}

const testing = std.testing;

/// The response shape /api/settings/get actually answers: the preset arrays are SIBLINGS of the
/// settings string, never inside it (settings.js:429 `response.send({ settings, ...payload })`).
/// The array below carries what the real directory can: a good preset, one whose fields are hostile
/// shapes, a non-object element and a nameless one.
const response_json =
    \\{"settings":"{}",
    \\ "instruct":[
    \\   {"name":"ChatML","input_sequence":"<|im_start|>user","output_sequence":"<|im_start|>assistant","wrap":true},
    \\   {"name":"Hostile","input_sequence":"<|hostile_user|>","output_suffix":null,"system_sequence":["nope"],
    \\    "stop_sequence":{"deep":"er"},"wrap":"yes","names_behavior":42,"activation_regex":{"unmodelled":true}},
    \\   "this is not a preset object",
    \\   {"input_sequence":"<|orphan|>"},
    \\   {"name":7,"input_sequence":"<|numeric_name|>"},
    \\   {"name":"","input_sequence":"<|empty_name|>"}
    \\ ],
    \\ "context":[{"name":"Default","story_string":"{{#if description}}{{description}}\n{{/if}}","story_string_position":0}]}
;

/// An instruct preset with the key set the client really ships: all 23 keys that appear in all 38 of
/// `default/content/presets/instruct/*.json`, enumerated against the files rather than recalled.
///
/// The two halves are marked so a test can assert on the WHOLE body rather than on the keys its
/// author happened to think of. Every value the client MODELS is `### `-prefixed, so the panel's own
/// values must displace all of them; every value it does not model is `UNMODELLED-`, and each must
/// survive a save untouched.
const shipped_instruct_json =
    \\{"name":"Alpaca",
    \\ "input_sequence":"### Instruction:","output_sequence":"### Response:","system_sequence":"### System:",
    \\ "stop_sequence":"### Stop","input_suffix":"### InSuffix","output_suffix":"### OutSuffix",
    \\ "system_suffix":"### SysSuffix","first_output_sequence":"### First","last_output_sequence":"### Last",
    \\ "story_string_prefix":"### Prefix","story_string_suffix":"### Suffix",
    \\ "wrap":true,"macro":true,"names_behavior":"force","system_same_as_user":false,
    \\ "activation_regex":"UNMODELLED-REGEX","skip_examples":true,
    \\ "user_alignment_message":"UNMODELLED-ALIGNMENT","last_system_sequence":"UNMODELLED-LAST-SYSTEM",
    \\ "first_input_sequence":"UNMODELLED-FIRST-INPUT","last_input_sequence":"UNMODELLED-LAST-INPUT",
    \\ "sequences_as_stop_strings":true}
;

/// A context preset with the 12 keys that appear in all 34 of `default/content/presets/context/*.json`.
/// This client models five of them, so a save that writes only what it models keeps five and deletes
/// seven: the worse half of the same defect.
const shipped_context_json =
    \\{"name":"Alpaca","story_string":"### {{description}}","chat_start":"### Start",
    \\ "example_separator":"### Examples","story_string_position":0,
    \\ "story_string_depth":4,"story_string_role":1,"always_force_name2":true,
    \\ "trim_sentences":true,"single_line":true,"use_stop_strings":false,"names_as_stop_strings":true}
;

fn parseResponse(a: Allocator, text: []const u8) !std.json.ObjectMap {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always });
    return root.object;
}

fn liveChatml() templates.Templates {
    return .{
        .instruct = .{
            .enabled = true,
            .name = "ChatML",
            .input_sequence = "<|im_start|>user",
            .output_sequence = "<|im_start|>assistant",
            .output_suffix = "<|im_end|>\n",
            .stop_sequence = "<|im_end|>",
            .wrap = true,
            .names_behavior = .none,
        },
        .context = .{ .name = "ChatML", .story_string = templates.default_story_string },
    };
}

test "collect keeps every nameable preset and skips only the ones it cannot name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const obj = try parseResponse(a, response_json);

    const list = try collect(a, obj, "instruct");
    // Four of the six elements are unusable in three different ways; the two good ones survive and
    // keep their file order. A typed parse would have returned zero.
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("ChatML", list[0].name);
    try testing.expectEqualStrings("Hostile", list[1].name);
}

test "collect carries a hostile preset's object through whole rather than dropping it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try collect(a, try parseResponse(a, response_json), "instruct");

    // The bad fields cost NOTHING at collect time: the object is judged only when it is applied.
    const hostile = list[1].value.object;
    try testing.expectEqualStrings("<|hostile_user|>", hostile.get("input_sequence").?.string);
    try testing.expectEqual(std.json.Value.null, hostile.get("output_suffix").?);
    try testing.expect(hostile.get("system_sequence").? == .array);
    // Even a field this client does not model at all is still there for the save to write back.
    try testing.expect(hostile.get("activation_regex").? == .object);
}

test "collect degrades an absent or non-array key to an empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const obj = try parseResponse(a, "{\"instruct\":{\"not\":\"an array\"},\"context\":42}");
    try testing.expectEqual(@as(usize, 0), (try collect(a, obj, "instruct")).len);
    try testing.expectEqual(@as(usize, 0), (try collect(a, obj, "context")).len);
    try testing.expectEqual(@as(usize, 0), (try collect(a, obj, "absent")).len);
}

test "collect reads the arrays as siblings of the settings string, not from inside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const obj = try parseResponse(a, response_json);

    // The shape the server really sends. A reader that mined the `settings` STRING would find no
    // presets at all, which is the thing that decided this module's design.
    try testing.expect(obj.get("settings").? == .string);
    try testing.expect(obj.get("instruct").? == .array);
    const inside = try parseResponse(a, obj.get("settings").?.string);
    try testing.expectEqual(@as(?std.json.Value, null), inside.get("instruct"));
}

test "buildOptions labels each option by the name its file gave it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try collect(a, try parseResponse(a, response_json), "instruct");
    const opts = try buildOptions(a, list);

    try testing.expectEqual(@as(usize, 2), opts.len);
    try testing.expectEqualStrings("ChatML", opts[0].value);
    try testing.expectEqualStrings("ChatML", opts[0].label);
    try testing.expectEqualStrings("Hostile", opts[1].value);
}

test "find returns the named preset and nothing for an unknown name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try collect(a, try parseResponse(a, response_json), "instruct");

    try testing.expectEqualStrings("Hostile", find(list, "Hostile").?.name);
    try testing.expectEqual(@as(?Preset, null), find(list, "Nonexistent"));
    // The nameless element is not reachable by the name it never had.
    try testing.expectEqual(@as(?Preset, null), find(list, ""));
}

test "a picked instruct preset that omits enabled leaves instruct wrapping ON" {
    // THE TRAP, and the reason this test is native: it fails SILENTLY. No shipped instruct preset
    // carries `enabled`, so a wholesale replace reads the struct default, instruct switches off, and
    // the user gets bare "Name: mes" lines after picking a template. Nothing prints.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const preset = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"Alpaca","input_sequence":"### Instruction:","output_sequence":"### Response:"}
    , .{ .allocate = .alloc_always });

    const blob = try blobWith(a, .instruct, preset, liveChatml());
    const back = try templates.parseTemplates(a, blob);

    try testing.expect(back.instruct.enabled);
    try testing.expectEqualStrings("### Instruction:", back.instruct.input_sequence);
    try testing.expectEqualStrings("### Response:", back.instruct.output_sequence);
}

test "a picked preset's fields win and the fields it omits keep their live values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Names only the input sequence, so every other live field must survive: the classic client's
    // `if (preset[control.property] !== undefined)` rule (instruct-mode.js:839).
    const preset = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"Partial","input_sequence":"### Instruction:"}
    , .{ .allocate = .alloc_always });

    const back = try templates.parseTemplates(a, try blobWith(a, .instruct, preset, liveChatml()));
    try testing.expectEqualStrings("### Instruction:", back.instruct.input_sequence);
    try testing.expectEqualStrings("<|im_start|>assistant", back.instruct.output_sequence);
    try testing.expectEqualStrings("<|im_end|>\n", back.instruct.output_suffix);
    try testing.expectEqualStrings("<|im_end|>", back.instruct.stop_sequence);
    try testing.expectEqual(templates.NamesBehavior.none, back.instruct.names_behavior);
    try testing.expectEqualStrings("Partial", back.instruct.name);
}

test "picking an instruct preset leaves the context half alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const preset = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"Alpaca","input_sequence":"### Instruction:"}
    , .{ .allocate = .alloc_always });

    var live = liveChatml();
    live.context.story_string = "{{#if description}}{{description}}\n{{/if}}{{#if anchorAfter}}{{anchorAfter}}\n{{/if}}";
    live.context.example_separator = "***";

    const back = try templates.parseTemplates(a, try blobWith(a, .instruct, preset, live));
    try testing.expectEqualStrings(live.context.story_string, back.context.story_string);
    try testing.expectEqualStrings("***", back.context.example_separator);
}

test "a picked context preset that predates the anchors gets them migrated in" {
    // THE OTHER SILENT ONE: without the marker drop, the preset inherits the live half's
    // story_string_position, parseContext reads it as already-migrated, and an author's note at
    // either anchor renders NOWHERE having worked a moment earlier.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const preset = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"Unmigrated","story_string":"{{#if description}}{{description}}\n{{/if}}"}
    , .{ .allocate = .alloc_always });

    const back = try templates.parseTemplates(a, try blobWith(a, .context, preset, liveChatml()));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, back.context.story_string, "{{anchorBefore}}"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, back.context.story_string, "{{anchorAfter}}"));

    // And the note now has a slot to render into, which is the whole point of the migration.
    const out = try templates.renderStoryString(a, back.context.story_string, .{ .description = "D", .anchor_after = "NOTE" }, .{});
    try testing.expectEqualStrings("D\nNOTE\n", out);
}

test "a picked context preset that carries the marker is left exactly as written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every one of the 34 shipped context presets looks like this: marker present, anchors already
    // placed. A second migration on top would duplicate the anchor blocks.
    const preset = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"Default","story_string":"{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}{{#if anchorAfter}}{{anchorAfter}}\n{{/if}}","story_string_position":0}
    , .{ .allocate = .alloc_always });

    const back = try templates.parseTemplates(a, try blobWith(a, .context, preset, liveChatml()));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, back.context.story_string, "{{anchorBefore}}"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, back.context.story_string, "{{anchorAfter}}"));
}

test "a hostile preset applies the fields that are readable and costs only the ones that are not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try collect(a, try parseResponse(a, response_json), "instruct");

    const back = try templates.parseTemplates(a, try blobWith(a, .instruct, find(list, "Hostile").?.value, liveChatml()));

    // The good field lands.
    try testing.expectEqualStrings("<|hostile_user|>", back.instruct.input_sequence);
    // Each bad field costs ITSELF: a null and an array read as empty, a number keeps the default.
    try testing.expectEqualStrings("", back.instruct.output_suffix);
    try testing.expectEqualStrings("", back.instruct.system_sequence);
    try testing.expectEqualStrings("", back.instruct.stop_sequence);
    try testing.expectEqual(templates.NamesBehavior.force, back.instruct.names_behavior);
    // `wrap` arrived as the junk string "yes" and DEFAULTS TRUE, so it must stay true: read as false
    // it would unwrap every turn in the prompt off one junk byte.
    try testing.expect(back.instruct.wrap);
    // And the preset never carried `enabled`, so wrapping is still on at all.
    try testing.expect(back.instruct.enabled);
}

test "blobWith refuses a preset that is not an object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.NotAnObject, blobWith(a, .instruct, .{ .string = "nope" }, liveChatml()));
    try testing.expectError(error.NotAnObject, blobWith(a, .context, .null, liveChatml()));
}

test "the overlay never writes into the stored preset a later pick reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try collect(a, try parseResponse(a, response_json), "instruct");
    const hostile = find(list, "Hostile").?;

    _ = try blobWith(a, .instruct, hostile.value, liveChatml());
    _ = try blobWith(a, .instruct, hostile.value, liveChatml());

    // Applying it twice must leave the library's own copy byte-identical: the overlay copies rather
    // than mutating, so the second pick sees what the first one did.
    try testing.expectEqualStrings("<|hostile_user|>", hostile.value.object.get("input_sequence").?.string);
    try testing.expectEqual(@as(?std.json.Value, null), hostile.value.object.get("enabled"));
    try testing.expectEqual(@as(usize, 8), hostile.value.object.count());
}

test "saveBody posts the three keys the route reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try saveBody(a, .instruct, "My Template", null, liveChatml());
    const sent = try parseResponse(a, body);

    // The field names ARE the contract: the route 400s without `preset` or `name`, and `apiId` is
    // what picks the directory it writes to.
    try testing.expectEqualStrings("My Template", sent.get("name").?.string);
    try testing.expectEqualStrings("instruct", sent.get("apiId").?.string);
    const preset = sent.get("preset").?.object;
    try testing.expectEqualStrings("<|im_start|>user", preset.get("input_sequence").?.string);
    // The name is stamped INTO the preset too, which is what the classic client writes and what
    // makes the file name itself when the directory is re-read.
    try testing.expectEqualStrings("My Template", preset.get("name").?.string);
}

test "saveBody names the context directory when the context half is saved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var live = liveChatml();
    live.context.story_string = "{{#if description}}{{description}}\n{{/if}}";
    const sent = try parseResponse(a, try saveBody(a, .context, "Lighthouse", null, live));

    try testing.expectEqualStrings("context", sent.get("apiId").?.string);
    const preset = sent.get("preset").?.object;
    try testing.expectEqualStrings("{{#if description}}{{description}}\n{{/if}}", preset.get("story_string").?.string);
    try testing.expectEqualStrings("Lighthouse", preset.get("name").?.string);
    // The marker rides along, so re-picking our own save does not migrate an already-migrated string.
    try testing.expectEqual(@as(i64, 0), preset.get("story_string_position").?.integer);
}

test "a saved preset picks back up as the same template" {
    // The round trip that matters: save the live templates, pick the saved preset back, and the
    // instruct half must come back unchanged.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sent = try parseResponse(a, try saveBody(a, .instruct, "Roundtrip", null, liveChatml()));
    const back = try templates.parseTemplates(a, try blobWith(a, .instruct, sent.get("preset").?, templates.Templates{}));

    try testing.expectEqualStrings("<|im_start|>user", back.instruct.input_sequence);
    try testing.expectEqualStrings("<|im_start|>assistant", back.instruct.output_sequence);
    try testing.expectEqualStrings("<|im_end|>", back.instruct.stop_sequence);
    try testing.expectEqual(templates.NamesBehavior.none, back.instruct.names_behavior);
    try testing.expectEqualStrings("Roundtrip", back.instruct.name);
    // The saved file carries no `enabled`, so picking it onto a set with instruct OFF leaves it off:
    // a preset is a template, and does not get to decide whether the picker uses instruct mode
    // (forbidden_keys). Inverted until 2026-07-16, when the save still wrote the toggle.
    try testing.expect(!back.instruct.enabled);
}

fn isForbidden(key: []const u8) bool {
    for (forbidden_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

test "a saved preset keeps every field the client does not model" {
    // THE DEFECT THIS FIXES: the save built the file from the MODELLED STRUCT, so all 7 unmodelled
    // fields of a shipped preset were deleted by anyone who picked it, nudged a sequence and saved.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = (try std.json.parseFromSliceLeaky(std.json.Value, a, shipped_instruct_json, .{ .allocate = .alloc_always })).object;
    const body = try saveBody(a, .instruct, "Mine", base, liveChatml());
    const preset = (try parseResponse(a, body)).get("preset").?.object;

    // THE PROPERTY, rather than the seven keys I enumerated: EVERY key the base carried is still
    // there. A field that a later SillyTavern adds to these files is covered by this test today, and
    // a test written to my list would have confirmed my list.
    var dropped: std.ArrayList([]const u8) = .empty;
    var it = base.iterator();
    while (it.next()) |e| {
        if (isForbidden(e.key_ptr.*)) continue;
        if (preset.get(e.key_ptr.*) == null) try dropped.append(a, e.key_ptr.*);
    }
    try testing.expectEqualStrings("", try std.mem.join(a, ",", dropped.items));

    // And by name and by value, because "the key is present" would pass on a key set to null.
    try testing.expectEqualStrings("UNMODELLED-REGEX", preset.get("activation_regex").?.string);
    // user_alignment_message is now MODELLED (client resolves it for the prompt), so the live value
    // wins over the base; liveChatml carries none, so the modelled empty string overwrites the base's.
    try testing.expectEqualStrings("", preset.get("user_alignment_message").?.string);
    try testing.expectEqual(true, preset.get("skip_examples").?.bool);
    try testing.expectEqual(true, preset.get("sequences_as_stop_strings").?.bool);
    // 23 keys: the shape of a shipped file, not a 16-key subset of one.
    try testing.expectEqual(@as(usize, 23), preset.count());
}

test "the panel's own values displace the base's for every field it models" {
    // The overlay direction is the risk the preservation fix introduces: based the wrong way round,
    // a save writes the FILE the user picked instead of the edits they just made, and every
    // preservation assertion above still passes.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = (try std.json.parseFromSliceLeaky(std.json.Value, a, shipped_instruct_json, .{ .allocate = .alloc_always })).object;
    const body = try saveBody(a, .instruct, "Mine", base, liveChatml());
    const preset = (try parseResponse(a, body)).get("preset").?.object;

    try testing.expectEqualStrings("<|im_start|>user", preset.get("input_sequence").?.string);
    try testing.expectEqualStrings("<|im_start|>assistant", preset.get("output_sequence").?.string);
    try testing.expectEqualStrings("none", preset.get("names_behavior").?.string);
    // Every modelled value in the base is `### `-prefixed, so ONE assertion says none of them
    // survived, under ANY key, including a key I never thought to check. The panel's live half sets
    // some of these to "", which is exactly where a base value hides from a per-field assertion.
    try testing.expect(std.mem.indexOf(u8, body, "###") == null);
    // The unmodelled half is untouched by the same rule, or the overlay would be a wholesale replace.
    try testing.expectEqualStrings("UNMODELLED-FIRST-INPUT", preset.get("first_input_sequence").?.string);
}

test "a saved instruct preset never carries instruct mode itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var base = (try std.json.parseFromSliceLeaky(std.json.Value, a, shipped_instruct_json, .{ .allocate = .alloc_always })).object;
    // A file that names itself: no shipped preset does, but a base is somebody else's file and the
    // clone keeps every key on purpose.
    try base.put(a, "preset", .{ .string = "Some Other Name" });

    const body = try saveBody(a, .instruct, "Mine", base, liveChatml());
    const sent = try parseResponse(a, body);
    const preset = sent.get("preset").?.object;

    // `enabled` is the toggle, not a template property: the classic client strips it from every
    // preset it writes and a file carrying `false` switches instruct off for whoever picks it.
    try testing.expect(preset.get("enabled") == null);
    try testing.expect(preset.get("preset") == null);
    try testing.expect(std.mem.indexOf(u8, body, "Some Other Name") == null);
    // The name still rides the envelope AND the preset, which is where each is read from.
    try testing.expectEqualStrings("Mine", sent.get("name").?.string);
    try testing.expectEqualStrings("Mine", preset.get("name").?.string);
    // The guard is not a blunt instrument: the field beside them survives.
    try testing.expectEqualStrings("UNMODELLED-REGEX", preset.get("activation_regex").?.string);
}

test "a saved context preset keeps the seven fields the client does not model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = (try std.json.parseFromSliceLeaky(std.json.Value, a, shipped_context_json, .{ .allocate = .alloc_always })).object;
    var live = liveChatml();
    live.context.story_string = "{{#if description}}{{description}}\n{{/if}}";
    live.context.example_separator = "***";

    const body = try saveBody(a, .context, "Lighthouse", base, live);
    const preset = (try parseResponse(a, body)).get("preset").?.object;

    // The client models 5 of the 12 keys, so this is the half of the defect that deleted more than
    // it kept: an unfixed save wrote 5 keys where the file had 12.
    try testing.expectEqual(@as(i64, 4), preset.get("story_string_depth").?.integer);
    try testing.expectEqual(@as(i64, 1), preset.get("story_string_role").?.integer);
    try testing.expectEqual(true, preset.get("always_force_name2").?.bool);
    try testing.expectEqual(true, preset.get("single_line").?.bool);
    try testing.expectEqual(true, preset.get("trim_sentences").?.bool);
    try testing.expectEqual(false, preset.get("use_stop_strings").?.bool);
    try testing.expectEqual(true, preset.get("names_as_stop_strings").?.bool);
    // The live half still wins where it models the field.
    try testing.expectEqualStrings(live.context.story_string, preset.get("story_string").?.string);
    try testing.expectEqualStrings("***", preset.get("example_separator").?.string);
    try testing.expect(std.mem.indexOf(u8, body, "###") == null);
    try testing.expectEqual(@as(usize, 12), preset.count());
}

test "with no preset to base on the save carries the modelled fields alone" {
    // The honest degradation: hand-edited templates match no preset, so there is no source object to
    // preserve from. This is the pre-fix behavior, and it stays correct for the case that earns it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const preset = (try parseResponse(a, try saveBody(a, .instruct, "Hand Made", null, liveChatml()))).get("preset").?.object;

    try testing.expectEqualStrings("<|im_start|>user", preset.get("input_sequence").?.string);
    try testing.expectEqualStrings("Hand Made", preset.get("name").?.string);
    try testing.expect(preset.get("activation_regex") == null);
    // The 20 modelled fields (user_alignment_message added) less the stripped toggle.
    try testing.expectEqual(@as(usize, 19), preset.count());
}

test "a preset saved from a base picks straight back up as the same template" {
    // The round trip the user actually performs: pick a shipped preset, save it under a new name,
    // pick the saved one back. The template must be the one they saved.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = (try std.json.parseFromSliceLeaky(std.json.Value, a, shipped_instruct_json, .{ .allocate = .alloc_always })).object;
    const sent = try parseResponse(a, try saveBody(a, .instruct, "Mine", base, liveChatml()));
    const back = try templates.parseTemplates(a, try blobWith(a, .instruct, sent.get("preset").?, liveChatml()));

    try testing.expectEqualStrings("<|im_start|>user", back.instruct.input_sequence);
    try testing.expectEqualStrings("Mine", back.instruct.name);
    // Picking our own save back does not turn instruct off, because the file does not carry the key.
    try testing.expect(back.instruct.enabled);
}

test "collect cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, text: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const obj = try parseResponse(a, text);
            const list = try collect(a, obj, "instruct");
            _ = try buildOptions(a, list);
        }
    }.run, .{@as([]const u8, response_json)});
}

test "blobWith cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, text: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const list = try collect(a, try parseResponse(a, text), "instruct");
            _ = try blobWith(a, .instruct, list[1].value, liveChatml());
        }
    }.run, .{@as([]const u8, response_json)});
}

test "saveBody cleans up on every allocation failure" {
    // Over the BASE path: cloning the base is the allocation the modelled-only save never made.
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, text: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const base = (try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always })).object;
            _ = try saveBody(a, .context, "My Template", base, liveChatml());
        }
    }.run, .{@as([]const u8, shipped_context_json)});
}
