//! Demo sections. Every hostile payload lives in Zig rather than in component props, because
//! client props are serialized into the SSR `<!--$id ...-->` marker and would otherwise appear
//! verbatim in the served HTML.

pub const Message = @import("./store.zig").Message;

pub const Section = struct {
    title: []const u8,
    note: []const u8,
    messages: []const Message,
};

const roleplay = [_]Message{
    .{
        .name = "Seraphina",
        .body =
        \\The lantern gutters as you push the door closed behind you. *She does not look up from the map.*
        \\
        \\"You're late. The tide turned an hour ago."
        \\
        \\Her finger traces a line south of the shoals, stopping at a mark you do not recognise.
        ,
    },
    .{
        .name = "You",
        .body =
        \\I lean over the table. "What is that?"
        \\
        \\> The parchment smells of salt and old smoke.
        ,
    },
    .{
        .name = "Seraphina",
        .body =
        \\"A wreck. Three days old." *She taps it twice.* "And **not** ours."
        \\
        \\Her jaw tightens.
        \\She rolls the map closed before you can read the rest.
        ,
    },
    .{
        .name = "You",
        .body =
        \\"Not ours," I echo. My hand closes over hers before the map can vanish. "Then say whose."
        ,
    },
    .{
        .name = "Seraphina",
        .body =
        \\*She lets the map go, but not the look.* "Vael colours. Black sails, a grey hull."
        \\
        \\A pause. "Salvagers don't fly a house."
        ,
    },
    .{
        .name = "You",
        .body =
        \\> Somewhere above, a floorboard settles.
        \\
        \\I lower my voice. "So it wasn't salvage."
        ,
    },
    .{
        .name = "Seraphina",
        .body =
        \\"It was a message." *She draws a second line, crossing the first.* "Left where the tide would carry it to *our* door, not theirs."
        ,
    },
    .{
        .name = "You",
        .body =
        \\"A warning, then. Or bait."
        \\
        \\I weigh the two and like neither.
        ,
    },
    .{
        .name = "Seraphina",
        .body =
        \\"Both, if they're clever." *She almost smiles.* "And they are clever."
        ,
    },
    .{
        .name = "You",
        .body =
        \\"Then we don't take the bait." *I straighten.* "We follow it back."
        ,
    },
    .{
        .name = "Seraphina",
        .body =
        \\*For the first time she looks up.* "You'd sail into Vael water on a hunch."
        \\
        \\"No." She rolls the map open again. "On **two**."
        ,
    },
    .{
        .name = "Quote styles",
        .body =
        \\All six of SillyTavern's quote forms colour the same way:
        \\"straight", “curly”, «guillemets», 「corner」, 『white corner』 and ＂fullwidth＂.
        \\
        \\*Italics outside a quote are grey.* "But *italics inside one* inherit the quote colour."
        \\
        \\A quote inside `"inline code"` is left alone, and so is one in a fence:
        \\
        \\```js
        \\const greeting = "not a quote";
        \\```
        ,
    },
};

const markdown_showcase = [_]Message{
    .{
        .name = "Seraphina",
        .body =
        \\# Heading one
        \\## Heading two
        \\
        \\Inline: **bold**, *italic*, ***both***, `inline code`, ~~struck through~~, and a [link](https://ziglang.org).
        \\
        \\A single newline breaks the line,
        \\like this, because `MD_FLAG_HARD_SOFT_BREAKS` is set.
        \\
        \\A blank line starts a new paragraph.
        \\
        \\> A blockquote.
        \\> It can span lines.
        \\
        \\- An unordered item
        \\- Another, with `code`
        \\
        \\1. Ordered
        \\2. Also ordered
        \\
        \\- [x] A completed task
        \\- [ ] An outstanding one
        \\
        \\| Extern | Meaning |
        \\| --- | --- |
        \\| `_snv` | set node value |
        \\| `_ce` | create element |
        \\
        \\---
        \\
        \\```zig
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    std.debug.print("hello {s}\n", .{"world"});
        \\}
        \\```
        \\
        \\```python
        \\def greet(name: str) -> str:
        \\    return f"hello {name}"
        \\```
        ,
    },
};

const png_pixel = "iVBORw0KGgoAAAANSUhEUgAAABwAAAAcCAIAAAD9b0jDAAAAX0lEQVR42u3UsQkAIAwF0T+3o1i6hoPZqiCImkLwCotAKgmvMqeQyjk5GnO/KVxs78LFHUXEBaXEiYLiQFmxo7hoo+8/V7i4o9R1CRcnyhZAuGgHxSvllfJKeaU+qlQFtIex08DphvAAAAAASUVORK5CYII=";

const security = [_]Message{
    .{
        .name = "Character card",
        .body = "<span class=\"danger\">Author HTML survives.</span> The class became `custom-danger`, so a card cannot restyle the app chrome. Benign <em>inline tags</em> pass through untouched.",
    },
    .{
        .name = "Hostile card",
        .body = "<img src=\"data:image/png;base64," ++ png_pixel ++ "\" onerror=alert(1)>" ++
            "\n\nThe image above is a real `data:image/png` URI and renders. Its `onerror` was stripped.\n\n" ++
            "<img src=\"data:image/svg+xml;base64,AAAA\">" ++
            "\n\nAn SVG `data:` URI sits above this line. Its `src` was removed entirely, because SVG can carry `<script>` and `onload`.\n\n" ++
            "<a href=\"javascript:alert(1)\">This link</a> kept its text and lost its `href`.\n\n" ++
            "<a href=\"https://ziglang.org\">A real link</a> keeps its `href` and gains `rel=\"noopener\"`.",
    },
};

pub const sections = [_]Section{
    .{
        .title = "A conversation",
        .note = "Quoted dialogue is wrapped in <q> before md4c runs and coloured orange; emphasis is grey. Both values are copied from SillyTavern's style.css. Quotes inside code are never wrapped.",
        .messages = &roleplay,
    },
    .{
        .title = "Markdown coverage",
        .note = "What MD_DIALECT_GITHUB plus MD_FLAG_HARD_SOFT_BREAKS supports: headings, lists, task lists, tables, rules and fenced code. Code blocks are highlighted from their language tag.",
        .messages = &markdown_showcase,
    },
    .{
        .title = "The sanitize boundary",
        .note = "Every body crosses env.sanitize before it can reach @escaping={.none}. Zig's SanitizedHtml type is the only value that renders raw, and only DOMPurify can mint one. Nothing here fires an alert.",
        .messages = &security,
    },
};
