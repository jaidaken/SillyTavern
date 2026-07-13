---
description: Reading-surface isolation model (hardened light-DOM island): motive, threat model, the 3 mechanisms, standing invariants, rejected alternatives, build plan.
tags: [client, css, reading, design, isolation, cascade-layers, ziex]
date: 2026-07-11
---

# READING-SURFACE ISOLATION MODEL (hardened light-DOM island)

status: design direction approved 2026-07-11 (operator picked C over shadow-DOM A and bare-CSS B). build NOT started; this doc = the spec for the build AND the standing contract after it.

## MOTIVE (why this exists)

- the chat area is the product; everything else is furniture. the reading surface carries the typography investment ([tier1 reading spec](tier1-reading-surface-spec.md)): book serif, justified prose, novel indent, reading themes/controls.
- two properties are protected, permanently:
  - P1 GEOMETRY: reading text never moves, reflows, or re-wraps because chrome changed (panel open/close/resize, drawer, future chrome features). a reflow destroys the reading position the reader's eyes hold; e-readers never re-typeset the page for a menu.
  - P2 TYPOGRAPHY: message styling is perturbable ONLY by sanctioned surfaces: themes (via tokens), the custom-css box, the reading controls. chrome CSS never reaches in, by accident or convenience.
- same principle as code layering inward-only: chrome may depend on the reading surface, never the reverse. the reading room does not know what happens in the hallway.

## THREAT MODEL

- the realistic threat = future FIRST-PARTY CSS: a careless selector written during next month's chrome work. NOT third-party code; this client has no extension system and injects no foreign styles.
- therefore the enforcement point is BUILD TIME (a gate that fails the commit), not RUNTIME (a shadow-DOM engine wall). an engine wall earns its cost when the boundary-crossers are unknown or many; here both sides of the boundary are this repo.
- runtime-injected CSS is out of scope by design: the only runtime style surface is the custom-css box, which is sanctioned (see M2).

## MECHANISMS

### M1 GEOMETRY: overlay panels + containment

- the left/right docks leave the `#chat-root` grid (today they are grid columns and opening one narrows the chat, `app.css:134`) and become top-layer overlays: `popover=manual` (Baseline 2024-04; manual = persistent, no light-dismiss, matches dock behavior). the top drawer already overlays.
- the grid collapses to a single centre column (topbar / chat / composer). chat geometry becomes a function of viewport + reading-measure ONLY.
- `#chat` gets `contain: layout style paint` -> engine-level guarantee: chrome DOM churn cannot invalidate chat layout, independent of any discipline.
- accepted trade (operator-chosen 2026-07-11): on a narrow viewport an open overlay covers part of the prose (a dock never occluded). panels are dismissible; on wide screens a <=620px dock mostly covers empty margin (prose column ~640px centred).

### M2 CASCADE: layers ordered so the chat always wins

- `@layer chrome, chat;` declared once. chrome rules live in `@layer chrome` (app.css), island rules in `chat.css` under `@layer chat`. later layer wins regardless of selector specificity (spec behavior) -> a chrome rule can never out-compete a chat rule, no specificity wars.
- chat.css rules are written inside `@scope (#chat)` blocks -> outbound containment: island rules physically cannot style chrome. (@scope Baseline 2025-12, FF146 closed the gap; acceptable floor for this client's audience.)
- themes keep working unchanged: they write TOKENS (`--bg`, `--accent`, `--st-quote`, ...). tokens inherit into the island; chat.css consumes them. a theme never writes a chat selector.
- the custom-css box is the ONE sanctioned unlayered surface. unlayered CSS beats all layers (spec behavior) -> user overrides always win, deliberately. the spec trap is the feature. INVARIANT: nothing else may ship unlayered.

### M3 GATE: build-time boundary checker

- new tool `.claude/tools/check-chat-isolation.cjs` (precedent: `find-orphan-labels.cjs` / `bake-labels.cjs` invariant checkers).
- parses every stylesheet except chat.css; FAILS the build when a selector could match inside `#chat`: explicit reaches (`.mes`, `.mes_text`, `#chat` descendants) or bare element selectors (`p`, `em`, `q`, ...) not scoped under a chrome ancestor.
- static analysis is conservative by design: false positives get an allowlist entry WITH a per-entry reason, reviewed not rubber-stamped. wired into `verify.sh` so the browser gate and the boundary gate run together.

## INVARIANTS (the standing contract after the build)

- I1: no non-chat stylesheet targets anything inside `#chat`. gate-enforced (M3).
- I2: chat.css never styles anything outside `#chat`. @scope-enforced (M2).
- I3: themes restyle the chat via tokens only, never via chat selectors.
- I4: the custom-css box is the only unlayered stylesheet in the app.
- I5: chrome open/close/resize causes zero chat layout work. containment-enforced (M1); verified by the render probe (chat node identity + scrollTop already asserted in `renderCountProbe`, `glue/main.js`).

## SCOPE: WHERE THIS MODEL APPLIES (and where it does not)

- the full model (gate + invariants + protected status) applies to the READING SURFACE ONLY. isolation pays where the contract is asymmetric: one side precious + long-lived, the other churning. chat vs chrome has that; chrome panels vs each other do not.
- chrome panels (settings, characters, user, ...) are PEERS in one design system and SHARE components by design (`panelchrome.zx`, seg buttons, panel-head). do NOT wall them from each other: per-panel gates = an N-panel permission matrix catching cosmetic bugs you would see instantly, while fighting the shared components.
- what DOES spread to panels (hygiene, near-zero cost, apply as each panel body gets built past `PanelEmpty`): one CSS file per panel body, rules in `@scope (.panel-x)` blocks, filed under sub-layers (`@layer chrome.settings`, ...). organization + anti-bleed, no gate, no ceremony.
- FUTURE FULL-CONTRACT MEMBERS: any region rendering user/model markdown (character card descriptions + greetings, persona text, world-info entries) shares the THREAT MODEL (untrusted content, sanitizer contract, sanctioned-styling-surfaces-only) and therefore the CONTRACT, but is NEVER part of the chat region itself (operator 2026-07-11). the contract is the reusable thing; chat is its first instance, not its owner. a new content region = its own DOM region + its own scoped CSS file under the content layer + gate coverage extended to it. shared: tokens, the sanitizer pipeline, the invariant pattern (I1-I5 instantiated per region). not shared: the DOM, the region's CSS file, the reading controls (chat-specific).

## REJECTED ALTERNATIVES (why not)

- A, shadow-DOM island: engine-enforced runtime wall. rejected as overweight for a single-consumer boundary (operator 2026-07-11: "we don't need an entire second DOM"). concrete costs it carried: 2 more vendored ziex patches forever (hydration marker TreeWalker starts at `document.body` and never descends into shadow roots, `.ziex/src/runtime/client/window/document.zig:330`; door event delegation walks `event.target.parentElement` and shadow retargeting blinds it, door `index.js:1188`, composedPath fix) + ~6 glue query sites + harness selector rework. browser risk: Firefox find-in-page inside open shadow roots unverified / historically absent; FF selection meta-bug 1590379 OPEN w/ 19 deps (checked 2026-07-11). ARIA idrefs cannot cross the boundary. platform state itself was NOT the blocker (all primitives Baseline; details in the wiki `wasm-zig-browser-ui` raw note `2026-07-11-dom-css-isolation-primitives.md`).
- B, bare scoped CSS: own file + convention only. rejected as too little: no priority guarantee (specificity wars stay possible), no enforcement (leaks discovered by seeing the regression), custom-css-box unlayered-beats-layered trap unmanaged.
- iframe: full document isolation. rejected outright: splits the wasm app across two documents, doubles the runtime, breaks selection/focus at the seam, manual theming bridge.

## BUILD PLAN (execute on green-light)

1. CSS split: app.css chrome rules -> `@layer chrome`; the ~330 chat-scoped lines -> `chat.css` in `@layer chat` + `@scope (#chat)`. layout.zx gains the chat.css link.
2. overlay panels: `.panel` out of the grid, `popover=manual` + `showPopover()` on mount (glue already observes `#shell` mutations); grid -> single column; panel animations kept; resize handle unchanged (getBoundingClientRect-based, not grid-dependent).
3. containment: `contain: layout style paint` on `#chat`; re-verify message animations + `content-visibility` interaction.
4. checker: `.claude/tools/check-chat-isolation.cjs` + `verify.sh` wiring + allowlist file.
5. verify: full browser gate + render probe (I5) + convergence critic w/ screenshot pass.
- design-probe first (riskiest slice): M2 cascade behavior end-to-end on a throwaway branch: chat.css + layer order + one reading theme + a custom-css override + a deliberately-leaking chrome rule that the gate must catch. probe report before the real build.

links: [tier1 reading spec](tier1-reading-surface-spec.md), [w05 css audit](audit-w05-css.md), [8-phase audit fix-plan](audit-2026-07-10.md).
