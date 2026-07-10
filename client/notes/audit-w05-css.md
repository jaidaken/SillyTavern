---
description: Exhaustive WD1-WD69 audit of client/glue/app.css (671 lines) at HEAD 5be4f1638. Colour, type, spacing, motion, a11y, distinctiveness, dead CSS. Findings only, no fixes applied.
tags: [audit, css, webdesign, a11y, apca, distinctiveness, client]
date: 2026-07-10
---

# app.css audit (w05, 2026-07-10)

HEAD at audit time: `5be4f1638` (not `bab3a3628` as briefed; 3 commits ahead on the same branch,
all lead-authored a11y/env fixes). app.css is 671 lines, not the 647 the earlier backlog cites, so
every line number below is re-read from the current tree.

Scope: `client/glue/app.css` in full (671 of 671 lines), cross-read against `client/app/pages/*.zx`
(10 files), `client/glue/main.js`, `app/pages/ui.zig`, `app/pages/ui_state.zig`,
`app/pages/markdown.zig`, `glue/vendor/hljs-theme.css`. Findings that the existing
`notes/audit-2026-07-10.md` already lists are omitted unless this pass adds a number or a
correction; where that happens the line says so.

Contrast is computed, not estimated: OKLCH to sRGB to APCA 0.1.9 and WCAG 2.x. Negative APCA Lc
means light text on a dark background; the magnitude is what matters.

Token hex, for reference:
`--bg #100e0c` `--surface #191714` `--surface-2 #26221e` `--border #332e2a` `--border-soft #26221f`
`--text #e2dfdb` `--muted #8f8a84` `--faint #67625d` `--accent #eaa350` `--accent-dim #cb914e`
`--st-quote #f2a359` `--st-em #918b84` `--on-accent #181008` `pre bg #0a0806`

## Colour

1. [BUG] `--st-quote` vs `--accent` (WD6, WD63, WD66) - `#f2a359` and `#eaa350`, dL 0.010, dC 0.000, dH 6deg. They are the same colour. Every line of spoken dialogue in the app is painted the interactive accent, so the accent can never mean "interactive", and the palette has no distinct brightness step between its two loudest roles.
2. [BUG] `--st-em` vs `--muted` (WD6) - `#918b84` vs `#8f8a84`, 2/255 per channel. Two tokens, one colour. Italic action prose renders identically to disabled chrome text. The backlog notes the near-identical L; the new fact is that st-em is also below the readable floor (see A11y #35).
3. [BUG] `.mes_text a` (WD4, WD40) - no rule exists. `markdown.zig:25` runs `MD_DIALECT_GITHUB`, which enables permissive autolinks, so `<a href>` reaches the DOM. UA default `#0000EE` on `--bg` is WCAG 2.05:1, APCA Lc -13.7. A link inside a message is unreadable. The backlog mentions "message links" only inside the Phase 5 plan line, never as a finding.
4. [BUG] `glue/vendor/hljs-theme.css` (WD3, WD26, WD66) - the vendored theme is stock GitHub Dark: `.hljs { color:#c9d1d9; background:#0d1117 }` plus `#ff7b72` `#d2a8ff` `#79c0ff`. `#0d1117` is a cool blue-tinted near-black inside an app whose every neutral is warm (hue 65-75). WD3: warm or cool, never both. None of it is tokenised.
5. [BUG] `.mes_text pre` (app.css:539) with `code.hljs` - `pre` paints `oklch(0.135 0.006 65)` and the nested `code.hljs` paints `#0d1117` on top, so a cool rectangle sits inset inside a warm one with the pre's `0.75rem 1rem` padding showing as a ring. `pre code.hljs { padding: 1em }` from the vendored theme then doubles the inset. Two backgrounds, two paddings, one code block.
6. [BUG] `--border` as a control boundary (WD4) - 1.44:1 on `--bg`, 1.34:1 on `--surface`. `--border` is the entire visual affordance of `.composer-input`, `.composer-btn` and `.seg`. WCAG 1.4.11 wants 3:1 where the boundary is what identifies the control. The composer field reads as borderless.
7. [NIT] `--border-soft` on `--bg` (WD12) - 1.22:1. The `.mes` hairline is the only structure in a deliberately bubble-free column, and at 1.22:1 it is below reliable perception on a bright display. Around 1.6-2.0 keeps the restraint and gains the separation.
8. [NIT] `.composer-btn.is-send:hover { filter: brightness(1.06) }` (app.css:438, WD26) - the hover state is derived by a filter rather than a token, while `--accent-dim` sits declared and unused. `brightness()` on an oklch amber is not perceptually uniform, and `filter` promotes the button to its own compositing layer.
9. [NIT] `#chat { scrollbar-color: var(--border) transparent }` (app.css:195, WD4) - thumb at 1.44:1 against its track. `.panel-body` (app.css:268) sets `scrollbar-width` but no `scrollbar-color`, so the two scrolling surfaces disagree. The backlog defers the webkit path; the contrast number is the reason it is worth doing.
10. [PASS] `--bg` `--surface` `--surface-2` `--text` (WD1, WD2, WD3) - all OKLCH, no `#000`/`#fff`, neutrals carry 0.006-0.010 chroma tinted warm in one direction only. `--text` on `--bg` is APCA Lc 87.2, WCAG 14.52. The foundation is correct; the failures above are roles layered on top of it.

## Type

11. [BUG] `.mes_text pre` with `.hljs-*` (WD11, WD45) - the vendored theme applies `font-weight: bold` (hljs-theme.css:84, :98) and `font-style: italic` (:93) to spans that resolve to `--font-mono`. Only IBM Plex Mono 400 and 500 are declared, and no Mono italic exists at all. The browser synthesizes both: smeared bold and sheared oblique, in the one place glyph fidelity is the point.
12. [BUG] `@font-face` block (app.css:9-16) with `--font-serif` fallback (WD43, WD45) - 8 faces, `font-display: swap`, no `preload` in `layout.zx`, and no metric-matched fallback (`size-adjust` / `ascent-override`). The fallback is Georgia, whose x-height and advance both exceed IBM Plex Serif, so the whole message column reflows when the real face swaps in. CLS target is 0. The backlog names the missing preload; the fallback metric mismatch is the part that actually shifts layout.
13. [DRIFT] `.mes_text` (app.css:474, WD7) - no `overflow-wrap`. One unbroken token (a URL, a hash, a base64 blob) overflows the 40rem column, and because `#chat` sets `overflow-y: auto` its `overflow-x` computes to `auto` too, so the chat pane grows a horizontal scrollbar. The backlog covers wide tables, not prose.
14. [BUG] `.composer-input` (app.css:382, WD7, WD14) - `flex: 1 1 auto` inside a full-width `#composer` with no `max-width`. On a 2560px viewport with no docks open the prose field runs roughly 290ch, and its left edge does not align with the centred 40rem message column directly above it. The user composes prose in a field four times the measure of the text it becomes.
15. [NIT] `--measure: 40rem` (app.css:54, WD7) - 608px of content at 17px IBM Plex Serif is about 74ch, the very top of the 45-75 band. During `swap` the wider Georgia fallback overshoots 75ch. 36-38rem leaves headroom for both.
16. [NIT] `--font-ui` / `--font-serif` / `--font-mono` (WD11) - three families in active use, not the permitted two. All three are cuts of one superfamily, so no two voices in the interface contrast with each other. See Distinctiveness #55.
17. [NIT] `.brand` 1.1rem (app.css:117), `.brand-beta` 0.58rem (:127), `:not(pre) > code` 0.85em (:555) (WD10, WD26) - one-off sizes off the type scale. The backlog names the 1.0625 scale break and the `pre` line-height; the brand pair is new.
18. [NIT] `.brand { letter-spacing: 0.01em }` (app.css:119, WD9) - positive tracking on the largest chrome text. WD9 wants 0 or negative as text enlarges.
19. [NIT] `.seg-btn { font-size: var(--text-sm) }` (app.css:358, WD7) - 13.6px on an interactive control label, the smallest tap label in the app.

## Spacing, alignment, depth

20. [BUG] `.panel { overflow: hidden }` (app.css:212) with `.panel-resize { right: -4px }` (:288) - the handle is 9px wide and offset 4px outside the panel, and the panel clips its own overflow. 4 of the 9px are clipped away. The grab target is 5px, and the `:hover` accent highlight is cut in half. The affordance is half the size it was drawn to be.
21. [BUG] `app.css` responsive strategy (WD13) - one `@media` block in 671 lines and it is `prefers-reduced-motion`. There is no breakpoint anywhere. `.drawers` is 9 buttons at 2.1rem plus gaps (about 19.5rem) sitting `space-between` from `.brand` in a `#topbar` with no wrap and no overflow rule, so the bar collides below roughly 360px. A dock opens at `min-width: 240px` against `#center { min-width: 0 }`, so the chat column can be squeezed to nothing. There is no mobile layout.
22. [NIT] `.top-drawer` over `#chat` (app.css:300, WD15, WD16) - elevation is carried entirely by `--surface` (L 0.205) over `--bg` (L 0.165). That is a 1.08:1 fill difference, wrapped in a 1.44:1 border, with no shadow (correct for dark UI per WD16). The overlay reads as cut into the page rather than resting above it. Widen the surface step, or add a light-from-above hairline on the drawer's top edge.
23. [NIT] `.mes_name::before` (app.css:465, WD14) - a 0.42rem square rotated 45deg presents a 0.59rem diagonal while keeping its 0.42rem box, so the optical gap to the name is about 0.41rem, not the declared `--s-2` 0.5rem. The marker also pushes the speaker name 0.92rem right of the prose column's left edge; a margin marker should hang outside the column so the name aligns with the body text beneath it.
24. [NIT] arbitrary values off the `--s` scale (WD13, WD26) - `.drawers { gap: 0.1rem }` (:139), `.brand-beta { padding: 0.1rem 0.34rem }` (:134), `.mes_name::before` 0.42rem (:467), `.composer-input { padding: 0.6rem 0.85rem }` (:387), `.top-drawer { top: calc(var(--topbar-h) - 4px) }` and `width: min(42rem, calc(100vw - 1.5rem))` (:302, :306). Meanwhile `--s-1` (0.25rem) is declared and never used.
25. [PASS] `.seg` r-2 5px + 2px padding + `.seg-btn` r-1 3px (app.css:343-360, WD17) - inner radius equals outer radius minus gap, exactly. Correct corner nesting on a radius scale that carries a written reason. This is the most disciplined thing in the file.

## Motion

26. [PASS] motion override, verified end to end (WD25) - `ui_state.zig:128 motionClass` yields `""` / `"motion-on"` / `"motion-off"`; `chat.zx:8` puts it on `<div id="app">`. `--move` is an inherited custom property, every animated element (`.panel`, `.top-drawer`, `.mes`, `.composer-btn`) is a descendant of `#app`, so `#app.motion-on { --move: 1 }` correctly overrides the `:root` reduce media query for the subtree. The DOMPurify `custom-` class prefixer at `glue/main.js:107` is gated on `config.MESSAGE_SANITIZE`, so it only ever rewrites message-body classes and cannot break the shell's motion class. Reduced motion keeps the opacity fade and drops movement, which is WD25 rather than the banned zeroing.
27. [BUG] `system` motion preference (WD25, WD38) - `motionClass(.system)` returns `""` and the OS media query governs, but `motionSegClass` still paints "System" as `is-active`. A user with `prefers-reduced-motion: reduce` sees "System" selected and no indication that movement is currently off. The control shows the preference, never the resolved state.
28. [NIT] `.composer-btn { transition: ... transform 90ms }` (app.css:666, WD20) - the press band is 100-160ms. 90ms is under it. Every other duration in the file is in band.
29. [NIT] `.panel` and `.top-drawer` (app.css:626, :634, WD18) - both have enter animations and no exit. Both are removed from the DOM on close, so each snaps out after easing in.
30. [QUESTION] `.mes { animation: mes-in 240ms }` (app.css:655, WD24) - a message is the highest-frequency element in a chat client, and WD24 says 100+ per day gets no animation. The comment's element-identity argument holds, so it fires once per message rather than per rerender. Keep it, or drop it on the frequency rule?

## Accessibility

31. [BUG] `page.zx:3` `<main id="chat-root">` around `chat.zx:15` `<main id="chat">` (WD36) - two nested `<main>` landmarks. HTML allows exactly one non-hidden `<main>` per document. Landmark navigation offers two "main" entries, and `#chat-root` has no rule in app.css at all, so it is a bare unstyled wrapper whose only effect is the violation. Not in the backlog.
32. [BUG] no `<h1>` in the document (WD36) - `layout.zx` sets `<title>` and no heading element exists anywhere in the shell. `.brand` is a `<div>`, `.panel-title` a `<span>`, `.mes_name` a `<div>`. Heading navigation yields nothing.
33. [BUG] `--muted` on `--bg` (WD4, WD40) - APCA Lc 39.5. WCAG is 5.61:1, which passes AA, and that is exactly why it went unnoticed. Lc 39.5 is beneath the Lc 45 floor for any text and far beneath the Lc 60 body target. It paints `.mes_name` (12px uppercase mono), `.panel-title` (12px), `.panel-empty`, `.setting-note`, `.seg-btn`, and blockquote body text. At 12px the APCA size table wants roughly Lc 90.
34. [BUG] `--faint` on `--bg` (WD4, WD40) - APCA Lc 21.4, WCAG 3.21:1. It fails WCAG AA for text outright, not just APCA. It is `.composer-input::placeholder`, which carries the only instruction the composer has. The backlog asks that this be verified; it fails.
35. [BUG] `--st-em` on `--bg` (WD4) - APCA Lc 40.2. The backlog asks whether it clears Lc 75. It does not, and it is not chrome: this is italic action prose at 17px, primary reading content in a roleplay client.
36. [BUG] `.panel-resize` (app.css:278, `sidepanel.zx:15`, WD37) - `aria-hidden="true"`, no `tabindex`, no keyboard handler. Dock width is pointer-only, with no keyboard path at all, and the 9px target (5px effective, per #20) is under the WCAG 2.2 24px minimum.
37. [DRIFT] `#composer` is a `<footer>` (`composer.zx:4`, WD35) - the composer is the app's primary text-entry region, not a document footer. Because it is not a body child it does not become a `contentinfo` landmark either, so it announces as a generic unlabelled region. `<form>` or a labelled `<section>` states the intent.
38. [DRIFT] `#topbar` is a `<header>` inside `#app` (`chat.zx:8`, `topbar.zx:5`, WD35) - a `<header>` nested in a `<div>` is not a `banner` landmark. The app's primary navigation region announces as generic.
39. [NIT] `.mes_text ul, ol` (WD40) - no rule, so UA `padding-inline-start: 40px` indents lists 40px into a 608px column, while `li.task-list-item { margin-inline-start: -1.2rem }` (app.css:571) compensates for checklists only. A bullet list and a checklist sit at different indents inside the same message.
40. [NIT] `.mes_text img { max-width: 100% }` (app.css:564, WD43, WD44) - no `height: auto`, so an image carrying width and height attributes is squashed when max-width clamps it. No `aspect-ratio` and no reserved space, so a remote image in a message shifts the whole column when it loads.
41. [PASS] `:where(button, textarea, [tabindex]):focus-visible` (app.css:89, WD37) - the ring is `color-mix(in oklch, var(--accent) 70%, transparent)`, which resolves to `#a9763b`: 4.92:1 against `--bg` and 4.58:1 against `--surface`, both clear of the 3:1 non-text floor, with `outline-offset: 2px` keeping it legible. The ring is right. Its selector list is not (backlog: missing `a`, `input`, `select`, `[contenteditable]`, `summary`).
42. [PASS] target sizes (WD37) - `.drawers > button` 2.1rem (33.6px), `.panel-close` 1.9rem (30.4px), `.composer-btn` 2.7rem (43.2px) all clear the 24px minimum. `.panel-resize` is the only control that fails, per #36.

## Rendering, template safety, architecture

43. [DRIFT] `layout.zx:9-10` (WD46) - two render-blocking stylesheets in `<head>`, and the hljs theme is only needed once a code block exists. No `preload` on the LCP font face.
44. [NIT] `#app` `#topbar` `#content` `#center` `#chat` `#composer` (WD34, WD26) - six ID selectors carrying visual style at specificity (1,0,0). The file header promises that "everything is a token so the theming system re-skins by overriding the `:root` block". A theme cannot restyle the topbar surface from `:root`, and cannot override an ID with a class. The stated theming contract holds for colour and breaks for structure.
45. [NIT] `app.css` at 671 lines (WD29, WD34) - one global stylesheet holding tokens, reset, layout, components, motion, and 12 inlined SVG data URIs. The backlog defers the split; the icon payload is the strongest argument for it, since those paths are content living in a stylesheet (WD32).
46. [PASS] template safety (WD47, WD48, WD49) - `.mes_text` is the only raw-HTML sink (`@escaping={.none}`, `message.zx:15`), it is fed through DOMPurify at the boundary with `style` forbidden as both tag and attribute, and `isSafeUri` (`main.js:76`) blocks `javascript:` and every non-image `data:`. No user data reaches an inline `style` or an `on*` attribute, and nothing in the CSS opts out.
47. [QUESTION] `glue/vendor/hljs-theme.css` - is the vendored GitHub Dark theme meant to stay stock, or be re-derived from the app's tokens? Every other surface in the app is a token, and this one is a different vendor's brand ramp.

## Distinctiveness (WD58-WD69)

Gate verdict: FAIL, and the failure is localised. The reading column passes. The chrome fails.

48. [PASS] WD58 brief - app.css:1-6 states one: warm low-glare dark surface, long roleplay sessions, prose is the hero, chrome recedes. That is a real WHO, WHAT and context of use. Most of the message column traces back to it cleanly.
49. [PASS] WD65 radius - `--r-1: 3px; --r-2: 5px; --r-3: 8px`, tight, with the reason written down ("tight and intentional, not pill-everything"), and correctly nested per #25. No blanket `rounded-xl`. This is what a decided radius looks like.
50. [PASS] WD70 background - a flat `--bg`, and the brief's low-glare long-session line earns the restraint. Decided, not left over. One gap: `#chat` and `.chat-inner` share the same fill, so the reading column has no surface of its own. In a room built for reading, the room and the paper are different materials.
51. [BUG] WD63 boldness spent nine times - `--accent` appears on `.brand-beta` text and border, `.mes_name::before`, `::selection`, the focus ring, `.seg-btn.is-active`, `.composer-btn.is-send`, the blockquote rule, `.panel-resize:hover`, and through the identical `--st-quote` (#1) on every line of spoken dialogue. WD63 asks for exactly one signature move with everything else quiet. One colour smeared across the whole surface reads as themed, not designed.
52. [BUG] WD60, WD63: the declared signature is not one - app.css:464 names the `.mes_name::before` diamond as the signature. It is a 6.7px rotated square. Nobody would describe it to another person, and it is not drawn from the subject's world; a rotated square is a UI-kit bullet. The real domain motif is already in the file and goes unnamed: the uppercase, letterspaced, monospace speaker name is the screenplay convention, which is precisely WD60's "materials, instruments, artifacts, vernacular" of roleplay. Promote that, cut the diamond.
53. [BUG] WD60, WD67 iconography - 12 hand-inlined Feather icons (app.css:579-590). Feather is a component-library icon set, and WD60 is explicit that a motif liftable from a component library is not a motif. Nine identical 2px-stroke, 24px-grid glyphs in a right-hand rail is the most recognisable "modern web app" chrome that exists. (`.i-plug` is also a lightning bolt, per the backlog.)
54. [BUG] WD64 the display face was not chosen for this brief - IBM Plex Sans/Serif/Mono clears the banned list, then lands squarely on the tier below it that WD64 names (the DM Sans / Manrope / Sora slope): the open-source superfamily a developer reaches for. Using three cuts of one superfamily means the display voice, the body voice and the chrome voice were all drawn by one hand at one time, so nothing contrasts with anything. Serif-for-prose is right and traces to the brief. Which serif does not. WD64's test asks: name why THIS face suits roleplay prose. The file has no answer.
55. [BUG] WD69 swap-the-logo - put any developer tool's wordmark in `.brand` and the topbar (wordmark left, mono uppercase "beta" pill, 2px-stroke icon rail right, warm near-black, 1px borders) and the composer (rounded field, filled accent send button, two ghost icon buttons) both remain plausible as that tool, unchanged. The message column does not: serif prose, amber speech, hairline separators, no bubbles, no avatars. The first 3rem and the last 4.5rem of the page were built from defaults, and they frame everything the brief actually got right. That framing is the whole of the "very AI" feeling.
56. [BUG] WD69 AI-default cluster 2 - the structure is near-black plus exactly one saturated accent, the second of the three clusters WD69 rejects unless the brief asks for it. The accent being amber rather than acid-green changes the hue, not the cluster. With #51, WD66's charge of a timid, evenly-distributed, unowned palette lands.
57. [BUG] WD68 stock copy - `placeholder="Type a message..."` (`composer.zx:6`) is the default of every chat product ever shipped. `.panel-empty` reads "Controls for this panel land here as each subsystem is wired." (`panelchrome.zx:18`), which is a developer's status note shown to a user; WD55 requires an empty state to say what the thing is and invite an action. The `beta` pill is stock SaaS chrome.
58. [QUESTION] WD61 two directions - no rejected direction is recorded in the file, in `notes/`, or in the commit trail. WD61 requires at least two distinct directions, with the rejected one and its reason written down. Was a second direction ever drawn?
59. [NIT] WD62 coherence - `.brand-beta`, the diamond, and the Feather rail cannot be traced to any line of the app.css:1-6 brief. WD62: if the line cannot be named, it is decoration, so cut it.

## Dead CSS and drift

60. [DRIFT] `.composer-btn.is-stop` (`composer.zx:8`) - the markup carries `is-stop`; app.css defines `.composer-btn.is-send` (:429) and nothing for `.is-stop`. The stop button is visually identical to the options button, and both render permanently beside a filled send button, so the composer displays three buttons and two mutually exclusive states at once.
61. [BUG] `.mes_code` (app.css:504) - dead, confirmed. The string appears nowhere in `app/` or `glue/` outside app.css. md4c emits `<pre><code>`, and `pre code.hljs` from the vendored theme already supplies `display: block; overflow-x: auto`. The backlog asks for confirmation; this is it.
62. [BUG] `--accent-dim` (:34), `--text-xl` (:50), `--s-1` (:57) - three declared tokens with zero `var()` consumers. The backlog names `--accent-dim` alone.
63. [BUG] `.composer-btn` transition (app.css:614) - dead. The grouped rule sets `transition: background 120ms ease, color 120ms ease`, then app.css:665 redefines `transition` in full for the same selector, so the first declaration never applies. Backlog item, line numbers shifted by the current tree.
64. [NIT] `#chat-root` (`page.zx:3`) - no rule in app.css. An unstyled `<main>` wrapper whose only observable effect is the nested-landmark bug at #31.
65. [NIT] `IBMPlexSans-600.woff2` (app.css:11) - no rule in the file requests IBM Plex Sans at 600. Its one reachable consumer is `<th>` inside a message table, which inherits `--font-ui` (app.css:528) and picks up the UA's `font-weight: bold`, matching down to the 600 face. One shipped font file, one accidental consumer.

## Blind spots

- No screenshot pass. This member is read-only and cannot build, so nothing here is graded from a rendered page. Every judgement is from the CSS source plus the `.zx` markup. WD69's swap-the-logo test is stated in the pack as a screenshot judgement; #55 is reasoned from the source and should be re-run against a real render before it is treated as settled.
- Synthetic bold and oblique (#11) are inferred from the declared `@font-face` set against the CSS Fonts 4 matching algorithm, not observed. Browsers differ on when they synthesize.
- APCA figures use the 0.1.9 formula. They are computed from the token values, not sampled from rendered pixels, so subpixel antialiasing and the `-webkit-font-smoothing: antialiased` on `body` will move perceived contrast slightly (usually downward, making #33 to #35 worse rather than better).
- The `~74ch` measure at #15 assumes an average advance of about 0.48em for IBM Plex Serif. Not measured against the actual font metrics.
- Theme override behaviour (#44) is reasoned from specificity, never exercised against a real second theme, because no second theme exists yet.
- `#chat` horizontal overflow (#13) follows from the CSS `overflow` propagation rules rather than an observed scrollbar.

## Index

Add to `client/notes/README.md` when it is created, alongside `audit-2026-07-10.md`. This document is
findings only. Nothing here was fixed, and no source file was touched.
