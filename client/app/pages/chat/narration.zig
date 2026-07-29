//! Gives a rendered message an addressable SHAPE: every paragraph becomes lines, and every line
//! becomes labelled runs. Layouts then style meaning instead of guessing at anonymous text.
//!
//! Two structures, both needed, both absent from what markdown emits:
//!   LINE - the model's paragraph. Measured over 93 assistant turns of a real chat: 419 single
//!          newlines against 29 blank lines, 14 to 1. A single newline is how a model ends a
//!          paragraph, and markdown renders it as a `<br>` inside one `<p>`, so six intended
//!          paragraphs arrive as one paragraph holding five breaks. Nothing could address them.
//!   RUN  - a stretch of narration between speech turns. Markdown puts narration, speech and more
//!          narration in one `<p>`; the narration after a turn is an anonymous box that no selector
//!          reaches and no `text-indent` touches (`each-line` does not reach it either, measured).
//!
//! WHY AFTER MARKDOWN, not in quotes.zig: markdown is what creates paragraphs. quotes.zig scans one
//! SOURCE line at a time, so wrapping there fragmented a single run across lines. Here a paragraph is
//! an explicit `<p>` and its pieces are contiguous.
//!
//! A line is a block in every layout (which is what the `<br>` it replaced already did); a run is
//! inline unless a script layout promotes it. So the inline layouts render exactly as before.

const std = @import("std");

const turn_q = "<q class=\"q-turn\"";
const turn_em = "<em class=\"em-turn\"";

/// Caller owns the result. OOM propagates.
pub fn wrapRuns(allocator: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < src.len) {
        const p_at = std.mem.indexOfPos(u8, src, i, "<p>") orelse break;
        const body_at = p_at + 3;
        const p_end = std.mem.indexOfPos(u8, src, body_at, "</p>") orelse break;

        try out.appendSlice(allocator, src[i..body_at]);
        try wrapParagraph(allocator, &out, src[body_at..p_end]);
        i = p_end;
    }
    try out.appendSlice(allocator, src[i..]);
    return out.toOwnedSlice(allocator);
}

/// One paragraph, split into LINES at its top-level `<br>`, each line wrapped as its own element.
///
/// This exists because of what the models actually do. Over 93 assistant turns of a real chat: 419
/// single newlines against 29 blank lines, 14 to 1. A single newline is how they end a paragraph, and
/// markdown renders it as a `<br>` INSIDE one `<p>`, so a turn the model wrote as six paragraphs
/// arrives as one paragraph with five line breaks. Nothing can address those pieces: no element, no
/// selector, and `text-indent` reaches only the paragraph's own first line. Giving each line an
/// element is what lets a layout treat the model's intended paragraph AS a paragraph, which is the
/// only way the flush-first-paragraph convention can hold (a first line has to be distinguishable
/// from the rest).
///
/// The `<br>` is CONSUMED: a line is a block, so it breaks by itself, and keeping the break as well
/// would leave an empty line between every pair.
fn wrapParagraph(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) std.mem.Allocator.Error!void {
    var i: usize = 0;
    var line_start: usize = 0;
    while (i < body.len) {
        // Turns are skipped whole, so a `<br>` inside an action beat never splits the line around it.
        if (turnAt(body, i)) |end| {
            i = end;
            continue;
        }
        if (brAt(body, i)) |end| {
            try emitLine(allocator, out, body[line_start..i]);
            i = end;
            line_start = end;
            continue;
        }
        i += 1;
    }
    try emitLine(allocator, out, body[line_start..]);
}

/// `<br>`, `<br/>` or `<br />` at `at`; the index just past it.
fn brAt(body: []const u8, at: usize) ?usize {
    if (!std.mem.startsWith(u8, body[at..], "<br")) return null;
    var k = at + 3;
    while (k < body.len and (body[k] == ' ' or body[k] == '/')) k += 1;
    if (k < body.len and body[k] == '>') return k + 1;
    return null;
}

fn emitLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) std.mem.Allocator.Error!void {
    if (line.len == 0) return;
    try out.appendSlice(allocator, "<span class=\"line\">");
    try splitSegments(allocator, out, line);
    try out.appendSlice(allocator, "</span>");
}

/// A line, cut into SEGMENTS at the speech that a novel would have started a paragraph with.
///
/// This is the part the model does not do for us and styling cannot fake. A real turn arrives as one
/// unbroken block: narration, then `"I want to taste you."`, then more narration, no break anywhere.
/// A novel sets the dialogue on a paragraph of its own, so indenting that block once changes nothing,
/// because the break the convention needs is not in the text. The app has to INSERT it.
///
/// A segment starts at each speech turn that follows real narration (an ACTION BEAT introducing
/// speech rides along instead: it is the attribution for the line after it). From the speech,
/// `chainEnd` extends the segment by the CMOS resumed-speech rule and decides where it closes.
///
/// Segments are INLINE by default, so Chat still renders exactly what the model wrote; only a layout
/// that means to impose paragraphing promotes them to blocks.
fn splitSegments(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) std.mem.Allocator.Error!void {
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], turn_q)) {
            if (i > seg_start and !isBeatOnly(line[seg_start..i])) {
                try emitSegment(allocator, out, line[seg_start..i]);
                seg_start = i;
            }
            const past = turnAt(line, i) orelse (i + 1);
            const cut = chainEnd(line, past);
            try emitSegment(allocator, out, line[seg_start..cut]);
            seg_start = cut;
            i = cut;
            continue;
        }
        if (turnAt(line, i)) |end| {
            i = end;
            continue;
        }
        i += 1;
    }
    try emitSegment(allocator, out, line[seg_start..]);
}

/// Where a SPOKEN segment ends, scanning from just past its opening speech turn.
///
/// The chain rule, CMOS ch.13: `"It was good," she says simply. "But I want more."` is ONE paragraph.
/// A dialogue tag belongs to its speech, and speech RESUMED by the same speaker after that tag
/// continues the same paragraph; a break there would tell the reader the speaker changed. Real miss
/// this fixed: `"Find out?" She repeats quietly, her voice shaking slightly. "You mean..."` arrived as
/// one model line and the old per-speech cut stranded `"You mean..."` on a paragraph of its own.
///
/// So from the speech, the segment carries: the tag (the FIRST sentence after the quote, a rule about
/// position, not meaning), any further speech directly after that tag, action beats standing between
/// speeches, and round again. It closes where narration outgrows attribution: at the second narration
/// sentence after a speech, or after a beat that no speech follows.
fn chainEnd(line: []const u8, from: usize) usize {
    var i = from;
    outer: while (true) {
        while (i < line.len and isSpace(line[i])) i += 1;
        if (i >= line.len) return line.len;

        if (std.mem.startsWith(u8, line[i..], turn_q)) {
            i = closeOf(line, i, "q") orelse return line.len;
            continue;
        }
        if (std.mem.startsWith(u8, line[i..], turn_em)) {
            const past = closeOf(line, i, "em") orelse return line.len;
            var k = past;
            while (k < line.len and isSpace(line[k])) k += 1;
            if (std.mem.startsWith(u8, line[k..], turn_q)) {
                i = closeOf(line, k, "q") orelse return line.len;
                continue;
            }
            return past;
        }

        // Narration: the tag runs to its first sentence end. A turn met before that is a mid-sentence
        // resume (`"A," she said and "B"`) and chains; other markup is stepped over, holding no prose.
        while (i < line.len) {
            if (std.mem.startsWith(u8, line[i..], turn_q) or std.mem.startsWith(u8, line[i..], turn_em)) continue :outer;
            if (line[i] == '<') {
                i = (std.mem.indexOfScalarPos(u8, line, i, '>') orelse return line.len) + 1;
                continue;
            }
            switch (line[i]) {
                '.', '!', '?' => {},
                else => {
                    i += 1;
                    continue;
                },
            }
            var run = i;
            while (run < line.len and (line[run] == '.' or line[run] == '!' or line[run] == '?')) run += 1;
            // An ellipsis is not a sentence end: `She paused... then smiled.` is one sentence.
            if (line[i] == '.' and run - i > 1) {
                i = run;
                continue;
            }
            var k = run;
            while (k < line.len and (line[k] == '"' or line[k] == '\'' or line[k] == ')')) k += 1;
            if (k >= line.len) return line.len;
            if (!isSpace(line[k])) {
                i = k;
                continue;
            }
            // Tag sentence complete at `k`. Resumed speech chains; anything else closes the segment
            // here, so a beat can still open the NEXT segment's speech via the beat-only rule.
            var m = k;
            while (m < line.len and isSpace(line[m])) m += 1;
            if (std.mem.startsWith(u8, line[m..], turn_q)) {
                i = closeOf(line, m, "q") orelse return line.len;
                continue :outer;
            }
            return k;
        }
        return line.len;
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Whether everything before a speech turn is just an ACTION BEAT, in which case the speech does not
/// start a new segment: it carries the beat with it.
///
/// `*She leans in.* "I want to taste you."` is one paragraph in print, because the beat is the
/// attribution for the line that follows. Splitting there would leave the beat stranded as a paragraph
/// of its own above the speech, which is the shape no novel uses. Prose narration before speech is a
/// different thing and does split: it is a paragraph that happens to be followed by dialogue.
fn isBeatOnly(seg: []const u8) bool {
    var saw_beat = false;
    var i: usize = 0;
    while (i < seg.len) {
        switch (seg[i]) {
            ' ', '\t', '\n', '\r' => {
                i += 1;
                continue;
            },
            else => {},
        }
        if (!std.mem.startsWith(u8, seg[i..], turn_em)) return false;
        i = closeOf(seg, i, "em") orelse return false;
        saw_beat = true;
    }
    return saw_beat;
}

fn emitSegment(allocator: std.mem.Allocator, out: *std.ArrayList(u8), seg: []const u8) std.mem.Allocator.Error!void {
    if (seg.len == 0) return;
    if (isBlank(seg)) {
        try out.appendSlice(allocator, seg);
        return;
    }
    try out.appendSlice(allocator, "<span class=\"seg\">");
    try wrapLine(allocator, out, seg);
    try out.appendSlice(allocator, "</span>");
}

/// One line's inline content, with EVERY narration run labelled, whether or not the line also holds a
/// turn. A turn-free line would render the same either way, but leaving those runs as bare text made
/// the shape depend on the sentence: some narration was an element and some was loose text, which is
/// the inconsistency that makes this markup hard to reason about and hard to style. One rule: a run
/// is a run.
fn wrapLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) std.mem.Allocator.Error!void {
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        const turn = turnAt(body, i) orelse {
            i += 1;
            continue;
        };
        try emitRun(allocator, out, body[run_start..i]);
        try out.appendSlice(allocator, body[i..turn]);
        i = turn;
        run_start = turn;
    }
    try emitRun(allocator, out, body[run_start..]);
}

/// A run is wrapped only when it carries something to read. Whitespace between two turns is not
/// narration, and wrapping it would render an empty line once the wrapper became a block.
fn emitRun(allocator: std.mem.Allocator, out: *std.ArrayList(u8), run: []const u8) std.mem.Allocator.Error!void {
    if (run.len == 0) return;
    if (isBlank(run)) {
        try out.appendSlice(allocator, run);
        return;
    }
    try out.appendSlice(allocator, "<span class=\"narr\">");
    try out.appendSlice(allocator, run);
    try out.appendSlice(allocator, "</span>");
}

fn isBlank(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r' => {},
            else => return false,
        }
    }
    return true;
}

/// If a block turn opens at `at`, the index just past its closing tag. Depth-counted on the turn's
/// OWN tag name: an action beat can hold a quote, and a bare `<q>` word inside must not be mistaken
/// for the beat's end.
fn turnAt(body: []const u8, at: usize) ?usize {
    if (std.mem.startsWith(u8, body[at..], turn_q)) return closeOf(body, at, "q");
    if (std.mem.startsWith(u8, body[at..], turn_em)) return closeOf(body, at, "em");
    return null;
}

fn closeOf(body: []const u8, at: usize, comptime tag: []const u8) ?usize {
    const open = "<" ++ tag;
    const close = "</" ++ tag ++ ">";
    var depth: usize = 0;
    var i = at;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], close)) {
            depth -= 1;
            i += close.len;
            if (depth == 0) return i;
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], open) and isTagBoundary(body, i + open.len)) {
            depth += 1;
            i += open.len;
            continue;
        }
        i += 1;
    }
    return null;
}

/// `<q` must not match the `<quote>` of some other element, so the byte after the name has to end it.
fn isTagBoundary(body: []const u8, at: usize) bool {
    if (at >= body.len) return false;
    return switch (body[at]) {
        ' ', '>', '\t', '\n', '/' => true,
        else => false,
    };
}

const testing = std.testing;

fn expectWrap(src: []const u8, want: []const u8) !void {
    const got = try wrapRuns(testing.allocator, src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const line_open = "<span class=\"line\">";
const seg_open = "<span class=\"seg\">";
const shut = "</span>";

test "wrapRuns_labels_a_run_even_when_the_paragraph_holds_no_turn" {
    // Same shape whatever the sentence contains: narration is always an element, never loose text.
    try expectWrap(
        "<p>Plain narration only.</p>",
        "<p>" ++ line_open ++ seg_open ++ "<span class=\"narr\">Plain narration only.</span>" ++ shut ++ shut ++ "</p>",
    );
    // A quoted WORD is not a turn, so it stays inside the run rather than splitting it.
    try expectWrap(
        "<p>A quoted <q>\"word\"</q> mid-sentence.</p>",
        "<p>" ++ line_open ++ seg_open ++ "<span class=\"narr\">A quoted <q>\"word\"</q> mid-sentence.</span>" ++ shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_splits_a_paragraph_into_lines_at_its_breaks" {
    // The model's single newline is its paragraph break: each side becomes its own line element, and
    // the <br> is consumed because a line is a block and would otherwise leave a blank line.
    try expectWrap(
        "<p>First line.<br>Second line.</p>",
        "<p>" ++ line_open ++ seg_open ++ "<span class=\"narr\">First line.</span>" ++ shut ++ shut ++
            line_open ++ seg_open ++ "<span class=\"narr\">Second line.</span>" ++ shut ++ shut ++ "</p>",
    );
    // Self-closing forms too.
    try expectWrap(
        "<p>A<br/>B<br />C</p>",
        "<p>" ++ line_open ++ seg_open ++ "<span class=\"narr\">A</span>" ++ shut ++ shut ++
            line_open ++ seg_open ++ "<span class=\"narr\">B</span>" ++ shut ++ shut ++
            line_open ++ seg_open ++ "<span class=\"narr\">C</span>" ++ shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_does_not_split_on_a_break_inside_an_action_beat" {
    try expectWrap(
        "<p>Before. <em class=\"em-turn\">a<br>b</em> after.</p>",
        "<p>" ++ line_open ++ seg_open ++ "<span class=\"narr\">Before. </span>" ++
            "<em class=\"em-turn\">a<br>b</em><span class=\"narr\"> after.</span>" ++ shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_starts_a_segment_at_speech_that_follows_narration" {
    // The shape a model actually emits, and the reason this pass exists: narration, speech, more
    // narration, no break anywhere. Print gives the dialogue a paragraph of its own, and the tag that
    // follows it belongs to that paragraph, so the cut goes before the speech and nowhere else.
    try expectWrap(
        "<p>She crossed the room. <q class=\"q-turn\">Stay.</q> he said, not turning.</p>",
        "<p>" ++ line_open ++
            seg_open ++ "<span class=\"narr\">She crossed the room. </span>" ++ shut ++
            seg_open ++ "<q class=\"q-turn\">Stay.</q><span class=\"narr\"> he said, not turning.</span>" ++ shut ++
            shut ++ "</p>",
    );
}

test "wrapRuns_cuts_a_real_turn_the_way_a_novel_sets_it" {
    // Verbatim from a model, one unbroken block, three speeches with narration woven between them.
    // Every cut below is a paragraph break a typesetter would make and the model did not.
    const src = "<p><q class=\"q-turn\">Y</q> Denny lets out a harsh laugh, kicking a can. " ++
        "Her eyes flick back to Winter. There's a weird flutter in her chest. " ++
        "<q class=\"q-turn\">A</q> She blushes, hating how pathetic she sounds. " ++
        "<q class=\"q-turn\">S</q> Her voice trails off. The air between them feels heavy.</p>";
    try expectWrap(src, "<p>" ++ line_open ++
        // Speech keeps its tag; the narration after the tag leaves.
        seg_open ++ "<q class=\"q-turn\">Y</q><span class=\"narr\"> Denny lets out a harsh laugh, kicking a can.</span>" ++ shut ++
        seg_open ++ "<span class=\"narr\"> Her eyes flick back to Winter. There's a weird flutter in her chest. </span>" ++ shut ++
        // Speech A's tag is followed by more speech, so the chain carries S and its tag with it.
        seg_open ++ "<q class=\"q-turn\">A</q><span class=\"narr\"> She blushes, hating how pathetic she sounds. </span>" ++
        "<q class=\"q-turn\">S</q><span class=\"narr\"> Her voice trails off.</span>" ++ shut ++
        seg_open ++ "<span class=\"narr\"> The air between them feels heavy.</span>" ++ shut ++
        shut ++ "</p>");
}

test "wrapRuns_does_not_cut_narration_that_is_not_a_dialogue_tag" {
    // Narration standing on its own is the model's paragraph and stays whole, however many sentences
    // it runs to. Only the sentence directly after speech is treated as attribution.
    try expectWrap(
        "<p>She crossed the room. The rain had not stopped. She waited.</p>",
        "<p>" ++ line_open ++ seg_open ++
            "<span class=\"narr\">She crossed the room. The rain had not stopped. She waited.</span>" ++
            shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_does_not_treat_an_ellipsis_as_the_end_of_a_tag" {
    try expectWrap(
        "<p><q class=\"q-turn\">A</q> She paused... then smiled. Rain hit the glass.</p>",
        "<p>" ++ line_open ++
            seg_open ++ "<q class=\"q-turn\">A</q><span class=\"narr\"> She paused... then smiled.</span>" ++ shut ++
            seg_open ++ "<span class=\"narr\"> Rain hit the glass.</span>" ++ shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_keeps_an_action_beat_with_the_speech_it_introduces" {
    // A beat is the attribution for the line after it, so it rides along instead of being stranded as
    // a paragraph above the speech. Only prose narration splits.
    try expectWrap(
        "<p><em class=\"em-turn\">She leans in.</em> <q class=\"q-turn\">Stay.</q></p>",
        "<p>" ++ line_open ++ seg_open ++ "<em class=\"em-turn\">She leans in.</em> <q class=\"q-turn\">Stay.</q>" ++
            shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_chains_speech_resumed_after_its_tag_into_one_segment" {
    // CMOS ch.13: `"It was good," she says simply. "But I want more."` is ONE paragraph. Cutting
    // before the resumed speech would tell the reader the speaker changed.
    try expectWrap(
        "<p><q class=\"q-turn\">A</q> she says. <q class=\"q-turn\">B</q></p>",
        "<p>" ++ line_open ++ seg_open ++
            "<q class=\"q-turn\">A</q><span class=\"narr\"> she says. </span><q class=\"q-turn\">B</q>" ++
            shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_keeps_the_real_resumed_speech_line_whole" {
    // Verbatim model output (Lena chat). The old per-speech cut stranded `"You mean..."` on its own
    // paragraph; it belongs at the end of this one.
    try expectWrap(
        "<p><q class=\"q-turn\">Find out?</q> She repeats quietly, her voice shaking slightly. <q class=\"q-turn\">You mean...</q></p>",
        "<p>" ++ line_open ++ seg_open ++
            "<q class=\"q-turn\">Find out?</q><span class=\"narr\"> She repeats quietly, her voice shaking slightly. </span><q class=\"q-turn\">You mean...</q>" ++
            shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_chains_through_an_action_beat_standing_between_two_speeches" {
    try expectWrap(
        "<p><q class=\"q-turn\">A wreck.</q> <em class=\"em-turn\">She taps it twice.</em> <q class=\"q-turn\">And not ours.</q></p>",
        "<p>" ++ line_open ++ seg_open ++
            "<q class=\"q-turn\">A wreck.</q> <em class=\"em-turn\">She taps it twice.</em> <q class=\"q-turn\">And not ours.</q>" ++
            shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_splits_a_run_at_a_line_break_into_two_lines" {
    // A break is the model ending a paragraph, so the two sides are separate lines, each its own run.
    try expectWrap(
        "<p><q class=\"q-turn\">A</q>she says,<br>still one run.</p>",
        "<p>" ++ line_open ++ seg_open ++ "<q class=\"q-turn\">A</q><span class=\"narr\">she says,</span>" ++ shut ++ shut ++
            line_open ++ seg_open ++ "<span class=\"narr\">still one run.</span>" ++ shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_does_not_wrap_whitespace_between_two_turns" {
    // Adjacent speeches chain (same speaker continuing); the space between them stays a bare space.
    try expectWrap(
        "<p><q class=\"q-turn\">A</q> <q class=\"q-turn\">B</q></p>",
        "<p>" ++ line_open ++ seg_open ++ "<q class=\"q-turn\">A</q> <q class=\"q-turn\">B</q>" ++ shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_treats_an_action_beat_as_a_turn_and_keeps_its_inner_quote" {
    try expectWrap(
        "<p>Before. <em class=\"em-turn\">she whispers <q>\"no\"</q> softly.</em> After.</p>",
        "<p>" ++ line_open ++ seg_open ++ "<span class=\"narr\">Before. </span>" ++
            "<em class=\"em-turn\">she whispers <q>\"no\"</q> softly.</em><span class=\"narr\"> After.</span>" ++
            shut ++ shut ++ "</p>",
    );
}

test "wrapRuns_handles_several_paragraphs" {
    try expectWrap(
        "<p>One.</p>\n<p><q class=\"q-turn\">A</q>tail.</p>\n",
        "<p>" ++ line_open ++ seg_open ++ "<span class=\"narr\">One.</span>" ++ shut ++ shut ++ "</p>\n" ++
            "<p>" ++ line_open ++ seg_open ++ "<q class=\"q-turn\">A</q><span class=\"narr\">tail.</span>" ++ shut ++ shut ++ "</p>\n",
    );
}
