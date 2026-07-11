---
description: Build spec for Tier 1 reading surface (native justified prose, gated), the reading-controls panel, and the settings sub-panel restructure. Ready to implement.
tags: [client, css, typography, reading, settings, design, spec, ziex]
date: 2026-07-11
---

# TIER 1 BUILD SPEC: READING SURFACE + CONTROLS + SETTINGS SUB-PANELS

status = designed + approved (operator 2026-07-11), NOT yet built. scoped to the MESSAGE READING AREA
only (`.mes_text`/`#chat`/`.chat-inner`); MUST NOT leak to global chrome (topbar/panels/composer).
Tier 2 (Knuth-Plass) is separate + deferred: [tier2-knuth-plass-justification.md](tier2-knuth-plass-justification.md).

## GROUNDING (verified from the code 2026-07-11)

- reading surface = `.mes_text` (app/pages/message.zx: `.mes` > `.mes_name` + `.mes_text`).
- a message SEALS on streaming->false (aria-busy flips). the memo reconcile means sealed messages never re-render.
- settings today = `SettingsBody` (settings.zx), ONE flat control (Motion, a `.seg` radio group).
- persistence pattern = glue owns localStorage + applies; Zig owns a reactive class the CSS reads. motion:
  `glue/main.js` ~573-600 reads `st-motion`, delegated listener on `[data-motion-set]`, localStorage set/get;
  `ui.zig` `setMotion`/`motionSegClass` own the reactive class. MIRROR this for reading prefs.
- theming = CSS vars on `:root` (`--bg --text --accent --text-md --measure --lh-prose`, OKLCH palette).

## A. READING SURFACE (glue/app.css + app/pages/message.zx)

1. reading vars on `#chat-root`, defaulted to CURRENT values (no visual shift until a control moves them):
   `--reading-size` (=`--text-md`), `--reading-measure` (=current `.mes_text` max-width, widenable), `--reading-lh` (=`--lh-prose`).
   `.mes_text` consumes them (font-size/max-width/line-height).
2. JUSTIFY, DOUBLE-gated (short RP turns must stay ragged):
   - message.zx: add class `mes-justify` to `.mes_text` ONLY when `body.len` > ~180 bytes (3-line proxy, comment the constant).
   - glue sets root class `reading-justify` from the pref.
   - css: `#chat-root.reading-justify .mes_text.mes-justify { text-align: justify; hyphens: auto; -webkit-hyphens: auto; hyphenate-limit-chars: 6 3 2; }`. keep `text-wrap: pretty`.
3. paragraph style, root class `reading-indent` = novel (first-line indent, no gap): `.mes_text p + p { text-indent: 1.4em; margin-block-start: 0 }`. default = current spaced.
4. `text-box`/`text-box-trim` on `.mes_text` for optical bubble text. VERIFY 2026 syntax + support at build; progressive no-op fallback; skip + report if support too thin.
5. `.mes { content-visibility: auto; contain-intrinsic-size: auto <sensible> }` for long-log perf. MUST verify via verify.sh it does not break the `.hydrated` reveal or streaming; scope to sealed/off-screen or drop + report if it does.
6. THEMES scoped to chat area only: root classes `reading-theme-sepia`/`reading-theme-paper` (default dark). override ONLY the reading container bg/text (scope `#chat`/`.chat-inner`/`.mes_text`, never `:root`). OKLCH, contrast >= WCAG AA. do NOT restyle chrome.

## B. CONTROLS + SETTINGS SUB-PANELS (settings.zx, panelchrome.zx, glue/main.js, ui.zig if reactive-state needed)

1. restructure `SettingsBody` into SUB-PANELS: accessible tablist (`role=tablist`, `role=tab`, `aria-selected`, roving tabindex) = `Reading` + `Appearance`, body = `role=tabpanel` showing the active. add tab-strip css.
2. `Reading` controls (motion-control template: real `<button>` + `data-*` + delegated glue listener): text size, measure, line-height, justify on/off, paragraph Novel/Chat, theme Dark/Sepia/Paper.
3. `Appearance`: MOVE the existing Motion control here.
4. glue wiring (mirror motion block): boot reads keys `st-reading-{size,measure,lh,justify,indent,theme}` from localStorage + applies to `#chat-root` (set custom prop or toggle class); delegated listener per control applies + persists on click; try/catch like motion.
5. DEFAULTS: operator prefers the novel look -> default `reading-justify` ON + `reading-indent` ON (toggleable); size/measure/lh = current; theme = Dark.

## C. CORRECTNESS
- tabs + controls keyboard-operable, aria-labelled, `:focus-visible` outline. no global-UI leak. no CSP issue (DOM + delegated listeners, no inline script, no external fetch).

## VERIFY
- `./build.sh` clean; `./verify.sh` all-green (12-fixture render, streaming, sanitize, door checks intact). node >=22 for the render driver (nix node 26 at `/nix/store/nk72hijagb0yc9rax5rr4gw8mpvmq7vw-nodejs-26.3.0/bin`).
- confirm a short fixture stays ragged (no `mes-justify`), a long one justifies.
- CSP-under-enforcement render check (render.mjs vs the enforcing CSP meta) since `.mes_text` is an innerHTML sink.
- do NOT deploy (operator: deploy only on request, see memory `no-auto-deploy-sillybeta`).

## EDIT SCOPE
authorized: glue/app.css, app/pages/message.zx, settings.zx, panelchrome.zx, ui.zig, ui_state.zig, glue/main.js, fixtures.zig (only if a test fixture is needed). do NOT touch build.sh/verify.sh/prune-dist.sh/patch-door.sh/fonts/door.
