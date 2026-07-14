---
description: Per-issue fix plans from the 2026-07-14 ziex-usage audit - dead handler cluster, reading-prefs lifecycle, glue dedup, README drift, data-layer-to-Zig migration, kv/region/rules decisions.
tags: [client, ziex, plan, events, glue, reading-prefs, character-panel, audit-followup]
date: 2026-07-14
---

# ziex-usage fix plan (audit 2026-07-14)

source audit: session 2026-07-14 vs ziex `26f5945`+5 patches. traps grounded in
[ziex event/interop traps](~/.claude/wiki/topics/wasm-zig-browser-ui/raw/notes/2026-07-14-ziex-event-interop-traps.md)
(wiki). status of each item = PLANNED until built + gate-verified.

## THE THREE TRAPS (fix vocabulary, referenced below)

- T1 currentTarget = body|null in ziex delegated dispatch -> handler MUST use `target` + parentElement walk.
- T2 jsz names are literal: no dotted paths (`dataset.x`, `style.height`), no `call(T,"",..)`, no window globals off `event.ref`. two-step: `get(js.Object,"dataset")` then `getAlloc(..,"x")`; window things from `zx.client.js.global`; getElementById via `zx.client.Document` (document.zig:179), never `get("getElementById")+call("")`.
- T3 bare component root -> failing allocator. fix = `zx.x.allocInit` + `zctx.cmp` (already the committed pattern, 2d99fc9fa).

## PHASE -1 - COMMIT THE PENDING WORKING TREE (recheck addition)

the uncommitted diff (wasm panic handler in main.zig+log.zig per Z102, + allocInit on 6 more panel bodies + character_list_region) is correct and load-bearing for phase 0's build. verify (`zig build` + `zig build test`) then commit as its own fix commit BEFORE phase 0.

## REBASE NOTES (d3f4ee76a, other agent, verified 2026-07-14)

phase -1 landed as 2d99fc9fa (other agent). d3f4ee76a adds: apiPost 403-refresh-retry helper (all JSON POSTs route through it), loadCharacterChat seq-ticket + aria-busy + error-keeps-view, boot = ?demo-gated fixtures + auto-open most-recent chat, server 500-on-unreadable-chat + 2 tests. verified independently: 6-file diff read, chat-data 65/65 re-run, verify.sh all-green re-run, build/test/check green, old frontend tolerant of the 500 at all 3 call sites. consequences here:
- phase 0 gate URLs need `?demo=1` (fixture predicates) - matches verify.sh's own change.
- phase 1 B4/B6 apply on the new custom.js shape (apiPost + seq ticket); bootInit already fixture-free, B6's applyAll call slots in unchanged; handlers.init() still present for D3.
- phase 3 Q1: net.zig must carry the 403-retry; char_api.zig must carry the seq-ticket + aria-busy semantics.
- open nits from the verify: ALL THREE FIXED by 7f3fe00e5 (demo fallback = truly-unreachable only, personas awaited before auto-open; test-cleanup nit NOT covered - still open, fold into phase 1). also adds: initCharacters bumps the load ticket, apiPost carries a never-for-generation-relays constraint (Q1 net.zig must inherit BOTH).
- 9d12349a3 fixed 2 of B4's 5 currentTarget sites (character_list.zx onCharSelect + onItemAction) via a local `datasetUp` target-walk helper + non-silent warn/info logging. B4 SHRINKS to: persona_list.zx:42, settings_body.zx:111, character_toolbar.zx:178, character_actions.zx:67 (its commit message hands these to this plan by name). F0 = HOIST datasetUp out of character_list.zx into dom_event.zig (same semantics, keep the logging pattern), don't write a second walk.
- verified 2026-07-14 19:0x wave (6 of 6 commits d3f4ee76a..8198ddf22 diff-read; zig build/test/check + verify.sh re-run green on final HEAD; dist = the verified artifact, built 22s pre-commit): ab36104c9+62b4754ee scroll-to-newest (self-caught selector miss), 465b7d0e4 visually-hidden 1px overflow pin, 8198ddf22 reading-width drag (B7's CHAT half: pointer-capture drag + arrows/Home + `st-reading-measurepx` persist + preset-click clears).
- B7 SHRINKS to the PANEL half only: `.panel-resize` drag + keyboard + `__st_set_panel_width` caller still absent. B7 additions from the wave: separator carries no aria-valuenow in markup (keyboard ops update nothing; add valuenow to BOTH separators), B6's server save should include `st-reading-measurepx`, and `st-reading-custom-measure` refs in settings_body.zx/reading_prefs.zig are now orphaned (the live key is measurepx) - fold into B1/B6.
- still-open nits for phase 1: corrupt-chat test rmSync -> afterEach; fetchCharacters catch treats a reachable 200-with-malformed-JSON as 'unreachable' (seeds demo over a half-broken backend).

## PHASE 0 - RUNTIME CONFIRM + CLICK GATE (before any fix)

goal: prove the dead-handler cluster in a real browser; leave behind a repeatable interactions gate so handler regressions can never ship silently again (verify.sh only checks message render + console today).

1. `zig build` (uncommitted diff included) -> `zig build export` -> `devserve.py --port 8080`.
2. new `interactions.mjs` (CDP, sibling of render.mjs; same chrome path discipline) driving:
   - drawer button opens settings (baseline: plain-handler path works).
   - reading "Small" click -> assert `#chat-root[data-reading-size]` UNCHANGED (bug confirmed) -> post-fix flips to CHANGED.
   - appearance tab click -> assert panel visibility (confirms B2).
   - motion "On" click -> assert `aria-checked` + seg highlight (confirms B3 desync).
   - inject 25 chars via `wasm.__st_add_character`/`__st_set_character_meta` from the driver -> open characters panel -> click pagination next (assert page label), fav star (assert net:debug fetch-attempt log line), row-child (avatar img) click (assert chat load attempt).
   - composer: type 3 lines -> assert height grew.
   - focus check: type in char search -> assert input keeps focus across the re-render (D4 evidence).
3. wire into `verify.sh` as a second gate stage. every later phase re-runs it.

- process: manager in-main (harness script, fully specified). deliverable: gate red on HEAD for the dead sites, plus a one-line result table into this doc.

### PHASE 0 RESULT (run on HEAD 8198ddf22, 2026-07-14)

BUILT: `interactions.mjs` (CDP real-input driver: clicks/keys/drags/console capture, must-vs-pending rows), `devserve.py --mock-api` (canned /csrf-token + characters/all 60 chars + settings/get personas + chats/get + edit-attribute w/ fav state), `verify-interactions.sh` (self-contained stage), verify.sh final stage (INTERACTIONS=0 skips). full verify.sh green incl. the new stage.

- must rows PASS (13): boot+12 fixtures, drawer open, composer autogrow, reading-width drag (8198ddf22), characters dock, boot auto-open Rita Recent, 60-char list, row-child click (9d12349a3), fav star + refetch, page-size select, search keeps focus + filters, persona dock.
- pending rows RED = the audit's dead cluster, runtime-confirmed (8): A3[B1] reading buttons, A4[B2] tabs, A5a/A5b[B2+B3] motion (UNREACHABLE: appearance panel display:none behind the dead tab handler - severity bump for B2), A9[B7] panel-resize drag, B6[B4] pagination next, B9[B4] persona row-child select, B10[B6] boot prefs re-apply.
- phase 1 contract: each fix flips its pending row(s) to 'must' in interactions.mjs in the same commit.

## PHASE 1 - HANDLER FIX WAVE (bugs B1-B6)

foundation first, then per-site fixes. one owner per feature: when a zx handler takes ownership, its custom.js delegate twin is DELETED in the same commit.

### F0 shared helper `app/pages/dom_event.zig` (new, zx-importing)

- `pub fn datasetValue(alloc, elem: js.Object, comptime key) ?[]u8` (two-step per T2, caller frees).
- `pub fn targetDatasetWalk(alloc, ev, comptime key) ?struct{ value: []u8, elem: js.Object }` - target + parentElement walk (T1), replaces 6 copy-pasted walk loops.
- `pub fn chatRoot(alloc) ?zx.client.Document.HTMLElement` via zx.client.Document (T2 getElementById fix).
- browser-verified per ZX5 (zx-importing module, not in native test run).

### B1+B2 reading controls + tabs (settings_body.zx)

- rewrite `onReadingClick` on F0: targetDatasetWalk("readingSet") -> localStorage from `js.global` -> chat-root attr via Document wrapper -> measure special-case via `get("style")` two-step -> syncAria -> debounced save.
- bind the two `.settings-tab` buttons to the same handler (they already carry data-reading-set="tab"); CSS keying exists.
- DELETE the copy-pasted logic in settings_body: it calls into `reading_prefs.zig` (the single owner, revived in B6).

### B3 motion (settings_body.zx + custom.js)

- fix dataset read via F0 two-step; handler then: `motion.set(pref)` (ctx.state, fixes highlight + aria-checked) + persist `st-motion` via js.global localStorage + call `ui` setter directly (plain fn, not the export hop).
- DELETE custom.js `data-motion-set` delegate block (single owner = zx).

### B4 currentTarget cluster (character_actions/character_list/character_toolbar/persona_list)

- `onCharAction`, `onItemAction`, `onPageStep`, `onPersonaSelect`, `onCharSelect` -> rewrite on F0 target-walk. CRUD actions keep calling `window.__st_char_*` glue (until Q1 lands); selection keeps `__st_load_character_chat`.
- DELETE custom.js `data-char-select` + `data-persona-index` delegates (zx owns; also fixes the child-click miss - walk covers avatar/name clicks).
- persona select: after `persona_store.global.select`, bump shell (currently only the JS path bumped).

### B5 composer auto-grow (composer.zx + custom.js)

- `get(js.Object,"style")` then `set("height",..)` two-step (T2), keep scrollHeight read.
- DELETE custom.js `input` delegate for `send_textarea`.

### B7 resize is dead: panel drag + reading-width drag never migrated (found on recheck)

- `ui.__st_set_panel_width` (ui.zig:104, "called from the resize glue") has ZERO JS callers; `.panel-resize` (sidepanel.zx:26) + `.chat-resize` (messagelog.zx:14) separators render inert; `st-reading-custom-measure` + `reading_prefs.saveNow` ("for resize handlers") are orphaned remnants. the drag glue lived in the deleted main.js (wiki hands-on note §9 cites it as the ZX7 example) and never crossed to custom.js.
- fix (ZX7: glue drives the gesture, Zig owns the state): pointerdown/setPointerCapture/pointermove/pointerup block in custom.js for both separators. panel: live width via inline style during drag, `wasm.__st_set_panel_width(isLeft, px)` on release. chat: live `--reading-measure` on #chat-root, persist `st-reading-custom-measure` + debounced server save on release.
- keyboard ops on both separators (they already carry `role=separator` + `aria-valuenow`): Arrow keys step width, via a zx `onkeydown` handler (ziex delegates keydown, eventTypeId 7) calling the same setters. aria-valuenow re-renders from state.
- phase-0 gate rows: drag panel edge -> width persists across re-render; arrow-key on focused separator -> width changes.

### B8 keyboard parity on interactive rows (found on recheck; WD37)

- char rows (character_list.zx), persona rows (persona_list.zx): `tabindex="0"` + onclick only - Enter/Space do nothing. add `onkeydown={ctx.bind(...)}` routing Enter/Space to the same select path (F0 helper reads `event.ref.getAlloc "key"` - Event.key() exists).
- gate row: focus char row -> Enter -> chat loads.

### B6 reading-prefs lifecycle (reading_prefs.zig owner)

- fix `getChatRoot`/`applyAll`/`syncAria`/`handleClick` internals per T2 (Document wrapper, no `call("")`).
- boot apply: `bridge.bootInit` calls `reading_prefs.applyAll()+syncAria()` (Zig-side; the never-called `__st_apply_reading_prefs` export + its JS absence both die).
- debounce: `zx.client.setTimeout(cb, 3000)` (window.zig:189, Zig callback) + pending-counter invalidation; delete the window-reflection timer in both files.
- server save: Q1-dependent. Q1 approved -> POST `/api/settings/get`->merge `clientReadingPrefs`->`/api/settings/save` from Zig via zx fetch (part of Q1 net layer). Q1 rejected -> rename custom.js `env.st_save_reading_prefs` to `window.__st_reading_save_now` and call from the Zig debounce cb. either way the current dead pair goes.
- delete `reading_prefs.onSaveTimeout`/`saveNow` (superseded), keep one save entry point.

- process: F0+B1-B6 = fully-specified small-logic edits -> manager in-main, then fresh-eyes `/sub audit` critic + phase-0 gate green (convergence). commit per feature-complete slice (F0+B1+B2+B6 one commit; B3, B4, B5 one each).

## PHASE S - ZIG-MAXIMAL REWRITE (operator directive 2026-07-14: "everything that can be zig or ziex, should be. JS only when we must." SUPERSEDES the JS-module-split-only plan below and FOLDS IN Q1; the old PHASE S text is kept beneath for the module boundaries it defined, now applied to the shrunken remnant.)

LOCKED PROPERTY: Zig owns everything ownable. the JS door shrinks to browser-forced adapters only.

### WHAT MOVES TO ZIG (with the enabling ziex API, all source-verified)

- Z-DATA (the old Q1): csrf token + 403-retry-once apiPost, characters/all + settings/get(personas) + chats/get fetch+parse, CRUD posts, auto-open-most-recent, selected state. via `zx` client fetch (`fetchAsyncCtx`, runtime/client/fetch.zig:70) + std.json (Z97 lifetime: alloc_always, copy into stores, deinit). `jsCharacters`/`personas`/`selectedPersona`/`csrfToken` in JS DIE. carries: never-retry-generation-relays constraint, ticket-bump on store rebuild, seq/aria-busy semantics, scroll-to-newest (jsz scrollIntoView call), malformed-JSON-200 = honest error not demo-fallback.
- Z-BOOT: boot orchestration (fetch chars+personas, auto-open vs ?demo vs unreachable-fallback decision) moves into bridge bootInit; ?demo read via ziex `_getLocationHref`. JS boot shrinks to door init + hydrated class + __st_boot_init call.
- Z-DIALOG: prompt/confirm/alert for CRUD via jsz `js.global.callAlloc` (String w/ optional for cancel) from the zx handlers. window.__st_char_* JS fns DIE except upload/download (below).
- Z-PREFS (B1/B2/B6): reading controls + tabs + boot apply + debounce (`zx.client.setTimeout`, window.zig:189) + server save through Z-DATA's net layer. env.st_save_reading_prefs + the window-save chain DIE.
- Z-MOTION (B3) + Z-COMPOSER (B5): zx handlers own; JS delegates DIE.
- Z-CLICKOUT: click-outside panel close as a zx onclick on the page root (dom_event ancestor walk for panel/drawers membership); document-level JS listener DIES.
- Z-LOGFILTER: category thresholds parsed + enforced IN log.zig (spec read once at boot via jsz localStorage); below-threshold messages never cross the boundary. JS keeps only the console sink + Error-object capture.
- Z-RESIZE-STATE (B7): panel width + reading measure state, keyboard resize (zx onkeydown per B8 pattern), aria-valuenow re-render. the pointer GESTURE stays JS (below).

### WHAT STAYS JS, EACH WITH ITS "MUST" (the whole remnant, target <=350 ln)

- bootstrap custom.js (~40): TrustedTypes default policy SYNCHRONOUS before any import (enforcing CSP throws on pre-policy innerHTML - the caught mistake, now pinned here), then dynamic-import of boot.
- boot.mjs (~60): vendor + ziex-door dynamic imports, env assembly, door.init, hydrated class. the door IS the JS boundary.
- sanitize.mjs (~150): DOMPurify + hljs ARE JS libraries; config, hooks, highlight cache, env.sanitize string IO (wasm read/write helpers live here or a tiny wasmio.mjs).
- stream.mjs (~100): SSE ReadableStream pump + rAF coalescing. ziex fetch is buffered whole-response (no streaming callback in 26f5945); rAF has no ziex binding. NOTE: a `_fetchStream` ziex patch is the future path to kill this; out of scope this wave (new framework surface + upstream divergence).
- adapters.mjs (~100): resize pointer-capture gesture (ZX7: glue drives the gesture, Zig owns the state - ziex's delegated mousemove cannot pointer-capture, cursor leaves vnodes mid-drag); file upload multipart (File/FormData cannot cross the wasm boundary; jsz has no promise/FileReader await); blob download (objectURL + a.click); global error/rejection capture (window listeners need JS callbacks; jsz cannot mint JS closures); click telemetry (DELIBERATE: must observe clicks outside zx vnodes, incl dead ones - it is the debug tool for exactly the silent-handler class).

### SEQUENCE (inverts the old order: Zig migration FIRST so B-fixes land in Zig once)

- S1 design-probe: DONE 2026-07-14, verdict MINOR (m-probe, 9/9 evidence rows, worktree discarded). amendments baked into S2:
  (a) fetchAsyncCtx is NOT on ziex's public surface (root.zig:104-109 re-exports only Fetch/Io/fetch; core/Fetch.zig:224 keeps client_impl private) -> use public `zx.fetch` + MODULE-GLOBAL request state in net.zig (csrf token, retry flag, chat-load seq are all naturally singleton; the JS did the same). fallback if a true multi-ctx wall appears: 1-line 07-patch re-exporting fetchAsyncCtx.
  (b) LEAK TRAP: the callback's Response is heap-created (client/fetch.zig:233); res.deinit() frees body+headers only -> net.zig wrapper MUST also allocator.destroy(res) or every fetch leaks.
  (c) Response.json() already wraps std.json (ignore_unknown_fields + alloc_always, core/Fetch.zig:142-148) - use it, no hand parse.
  (d) sync bumpShell from inside the fetch callback WORKS (scheduleRender is synchronous, microtask stack clean) - no deferral.
  (e) url/body/headers are copied synchronously by the door at _fetchAsync - stack buffers fine.
  (f) jsz prompt/confirm reflection works incl. cancel-as-null.
  probe blind spots -> S2 verification adds: a big-payload mock row (500 chars, long descriptions) for parse memory/latency; concurrency stays untested (64-slot registry, accept).
- S2 Z-DATA + Z-BOOT + Z-DIALOG build (member in worktree, VISIBLE tmux teammate per operator pref): net.zig, char_api.zig, bridge/bootInit rewrite, custom.js data layer deleted in the same slice. THE INTERACTION GATE IS THE ACCEPTANCE HARNESS: B1-B9 must rows exercise this entire path against the mock API and must stay green byte-identical.
- S3 B-wave in Zig: Z-PREFS (flips A3/A4/B10), Z-MOTION (A5a/A5b), Z-COMPOSER (A6 stays green w/ JS delegate deleted), Z-CLICKOUT, Z-RESIZE-STATE + adapters gesture for panels (flips A9), Z-LOGFILTER. gate rows flip pending->must per slice, same-commit.
- S4 door slim + split into the remnant shape above (move-only of what is LEFT); build.sh minify glob, prune-dist KEEP glob, layout.zx modulepreloads; D5 monkey-patch dies here (boot.mjs is a rewrite anyway).
- S4b STYLING ARCHITECTURE (operator pick B + "cleanest, most consistent, no monoliths", 2026-07-14). researched, not pattern-matched. rejected alternatives recorded at the end.

  MEASURED STATE: tailwind v4.3.2 fully wired (`@import "tailwindcss"` + `@theme` mapping 14 OKLCH tokens + `@source` scan of app/**/*.zx|zig + a 40-name safelist) but markup uses exactly ONE utility (`hidden`). all styling = 1272 ln app-base.css + 347 ln app-responsive.css. RULE INVENTORY of app-base.css (212 rules): 142 rules / 701 decls = CHROME on elements we author (67%); 43 rules / 146 decls = generated-prose descendants; 17 rules / 48 decls = data-reading/data-tab state; 6 = pseudo-element primitives; 4 = font-face/keyframes/media. DEFECT FOUND: the 14 colour tokens are defined TWICE (`:root` in app-base.css AND `@theme` in app-input.css, same oklch values) - two sources of truth, drift uncaught.

  THE ONE RULE (this is the consistency the old plan lacked): **if the element's class is authored by us, its style is a utility in the markup. if the HTML is generated at runtime, its style lives in the reading stylesheet.** that boundary is architectural (it mirrors zig-owns-state / JS-owns-browser-APIs), not a fatigue line, and it is exactly the case tailwind's own docs point `prose` at.

  ZIG <-> CSS CONTRACT (kills the safelist): Zig emits SEMANTIC state classes + data-attrs ONLY (`is-open`, `is-selected`, `is-fav`, `panel-left`, `motion-off`); markup declares what they LOOK like via `@custom-variant` (`@custom-variant selected (&.is-selected)` -> `selected:bg-surface-2 selected:border-accent`). consequence: the classes Zig computes are no longer tailwind classes at all, they are selector hooks the variants key on -> the 40-name `@source inline(...)` safelist DIES, and scanner-blindness becomes structurally impossible. NEVER compose a utility name at runtime in Zig (`"text-" ++ size` is banned; tailwind cannot see it).

  PRIMITIVES BECOME FIRST-CLASS (the old plan wrongly called these "leftover CSS"): the 13 icon masks -> `@utility i-cog { mask-image: ... }` (real utilities, compose with variants); the candlelight margin-rule signature (WD63) -> `@utility`; motion keyframes + the `--move` reduced-motion scale -> `@theme --animate-*`; fonts -> `@theme --font-*`. a component pattern repeated 3+ times (seg-btn, panel chrome, char-item base) -> a named `@utility`, NOT an `@apply` blob (v4 sanctions @utility; @apply is the escape hatch for HTML you do not control, per tailwind docs).

  FILES AFTER (every one under 300 ln, zero monoliths, one purpose each):
  - `glue/app-input.css` (~10 ln, entry, name kept so build.sh is untouched): tailwind import + the three below + `@source`.
  - `glue/theme.css` (~120 ln): `@theme` = THE SINGLE token source (the duplicate `:root` block DIES), fonts, animations; all `@custom-variant` definitions (the Zig state hooks).
  - `glue/primitives.css` (~130 ln): `@utility` icons + repeated component patterns + the signature.
  - `glue/reading.css` (~250 ln): the reading surface, ONE domain = the data-reading/data-tab state machine (which sets the reading custom properties on #chat-root) + the generated-prose descendant rules (q/em/blockquote/pre/code/hljs/tables/lists, the RP conventions). the app's soul; "the one X for its domain" per coding-style FILE SIZE.
  - `app-base.css` DELETED. `app-responsive.css` DELETED (its media queries become `md:`/`lg:` variants inline, next to the markup they modify).
  - component styling lives in the `.zx` files themselves. NO per-component css files. co-location is total.

  STEPS: S4b.1 rule-by-rule inventory -> MIGRATE / READING / PRIMITIVE / DEAD (counts, in this doc). S4b.2 build theme.css + primitives.css + reading.css; delete the duplicate token block; app.css output byte-diffed for sanity. S4b.3 migrate ONE region per commit (chat frame, shell/topbar, docks+drawer, panels: char list/toolbar/actions/persona/settings, composer), each deleting its app-base block as it lands. S4b.4 fold app-responsive into variants, delete the file. S4b.5 delete app-base.css remnant + the safelist; re-audit `@source`.

  GATES per commit: verify.sh incl. the interaction gate (its selectors key on the SEMANTIC names .char-item/.mes/.seg-btn - those MUST survive; they are the app's API to Zig AND to the gate). VISUAL: CDP screenshot per region before/after (the interactions harness already drives chrome; add a `--shot` mode) - a utility migration that moves a pixel is a BUG, not a restyle. FINAL: the webdesign convergence critic grades the screenshots (WD1-WD25 + the WD69 distinctiveness gate; the candlelight signature must survive intact).

  REJECTED, with reasons (so the space is on record):
  - ziex `zx.Style` (typed CSS-in-Zig, style/generated.zig): INLINE-ONLY. no pseudo-classes, no media queries, no descendant selectors, no ::before. correct tool for computed VALUES (the panel width already uses a hand-built "width:340px" string; upgrade THAT to typed `zx.Style` for consistency) but it cannot be a styling system.
  - `@tailwindcss/typography` (`prose`): a dependency whose defaults we would override almost entirely (our RP conventions - warm-amber `<q>`, muted-italic action text, the reading measure - are custom). reading.css is smaller than the override sheet would be.
  - drop tailwind, co-locate one .css per component: 14+ files, global namespace, and we hand-maintain what the utility scale gives free. also contradicts the operator's B pick.
  - shadow DOM / scoped styles: already rejected in reading-surface-isolation-model.md (find-in-page + selection breakage in firefox); ziex has no scoped-style feature.

- S5 phase 2 leftovers: README rewrite (now documents the Zig-maximal split + the tailwind adoption), dead-shim sweep (mostly already dead by S4), test-cleanup afterEach nit, D6 leak, region-comment truth (D4). then rules promotion (3b).

### OLD PHASE S TEXT (module boundaries reference; superseded as a standalone phase)

WD29 breach: ~950 ln, one IIFE, 9 unrelated jobs in shared closure scope. split = MOVE-ONLY, zero
behavior change, reviewed as pure movement; the pending B-item fixes and the phase-2/Q1 deletions
land ON the new files afterwards. entry contract unchanged: build.zig `jsglue_href` keeps pointing
at `glue/custom.js`, which becomes a ~40 ln CLASSIC bootstrap: (1) install the TrustedTypes default
policy synchronously (must precede every innerHTML under the enforcing CSP), (2) dynamic-import
boot.mjs on DOMContentLoaded (same pattern as the vendored purify/hljs; no bundler, no npm).

### MODULES (glue/mod/*.mjs, each <~150 ln)

- log.mjs: category logger + st_log filter + global error/rejection capture. exports log, logFor.
- wasmio.mjs: the wasm exports handle (setWasm/getWasm) + readString/writeRaw/writeBytes/writeString/freeRaw. THE shared-state seam: everything imports this instead of closing over `let wasm`.
- sanitize.mjs: DOMPurify MESSAGE_CONFIG + hooks + isSafeUri, highlight cache, highlightBlocks/highlightSealedBlocks, the streamRender flag (owner) + setStreamRender(). exports installSanitizer(DOMPurify, hljs), sanitizeHtml, highlightSealedBlocks, setStreamRender. NOT the TrustedTypes policy: that stays in the classic custom.js bootstrap, installed SYNCHRONOUSLY before any import resolves - under the live edge's enforcing require-trusted-types-for CSP, any innerHTML that lands before the default policy exists THROWS, so the policy must beat the entire dynamic-import chain, not ride inside it.
- stream.mjs: startStream pump + stats + devMode. imports wasmio, log, sanitize(setStreamRender+highlightSealedBlocks).
- api.mjs: csrfToken + ensureCsrfToken + withCsrf + apiPost (403-retry). boundary matches Q1's net.zig so Q1 shrinks/deletes whole files.
- chars.mjs: jsCharacters/personas/selectedPersona, initCharacters/addCharacterToWasm/fetchCharacters/autoOpenRecentChat/fetchPersonas/appendMessageInWasm/loadCharacterChat, charApiPost + the window.__st_char_* + __st_load_character_chat surface (zx handlers keep calling window.*). Q1 deletes most of this file wholesale.
- env.mjs: assembles the extern env object (st_log, sanitize, sse_start, st_save_reading_prefs + the dead shims until phase 2 deletes them) from log/wasmio/sanitize/stream. exports makeEnv().
- delegates.mjs: click telemetry, motion delegate (until B3 deletes it), composer autogrow (until B5), click-outside.
- resize.mjs: chat-resize drag/keyboard/persist block; B7 adds the panel-resize half here.
- boot.mjs: init() (vendor + door dynamic imports, instantiate capture until D5, hydrated class, __st_boot_init, demo seeding + Promise.all boot, dev-mode stream params). exports boot().

import graph (acyclic): custom.js -> boot -> {env, chars, stream, delegates, resize}; env -> {log, wasmio, sanitize, stream}; stream -> {log, wasmio, sanitize}; chars -> {log, wasmio, api}; api -> {log}; resize/delegates -> {log, wasmio}.

### STEPS

S1 write the 10 files (move code verbatim; only the seams change: wasmio accessor replaces the closure `wasm`, setStreamRender replaces the shared flag, explicit exports replace scope sharing).
S2 build.sh: minify loop globs dist/glue/mod/*.mjs (--format=esm) alongside the existing entries.
S3 prune-dist.sh: KEEP gains a glue/mod/*.mjs glob (fonts-style find, not hand-listed entries).
S4 layout.zx: modulepreload links for boot.mjs + its static import chain (flattens the dynamic-import waterfall; same rationale as the font preloads).
S5 verify: build.sh -> verify.sh FULL (render + interaction gates must be byte-identical green: 16 must rows, 6 pending unchanged) -> eslint on glue/ if the repo lint covers it.
S6 fresh-eyes critique (visible teammate per operator pref), fix, re-verify, commit.

### GUARDS

- move-only discipline: any behavior delta found in review = a defect in the split, not an improvement opportunity. improvements land as their own later commits.
- boot ORDER preserved: TT policy + env complete before door.init; DOMContentLoaded gate stays in custom.js.
- devserve /client-prefix strip already serves nested paths; no server change.
- sillybeta deploy unchanged + NOT auto-deployed (standing memory).

## PHASE 2 - DRIFT CLEANUP (D1-D5)

- D1 README.md rewrite: door = custom.js via `client.jsglue_href`; env surface = `sanitize`+`st_log` only; region architecture (Shell/MessageLog/Composer CSR + nested-region fallback truth); regenerate layout listing incl. panels/; drop render_code/sse_start/ChatView-singleton text; FIX "No npm, no node" claim - build.sh shells `npx esbuild` + `@tailwindcss/cli` (recheck addition; runs via nix develop). (out of doc-frontmatter scope per rule - README = index register.)
- D2 custom.js dead shim deletion: `st_elem_*`, `st_node_*`, `st_qsa`, `st_node_list_*`, `st_release_handle`, `st_style_remove_property`, `st_local_storage_*`, `st_save_reading_prefs` (unless B6-no-Q1 keeps its body as `__st_reading_save_now`), `env.sse_start`, `_handleMap`/`_nextHandle`. sse re-added when the send loop lands (git remembers).
- D3 dead zig: delete `handlers.zig` (+ bridge's `handlers.init()` call + bridge's inline motionCode dup -> use `ui_state.motionPrefFromStr`); settings_body loses its copy-paste block (done in B1); stale header comments in settings_body ("glue owns persistence") + handlers-claim corrected.
- D4 region-scoping comments (character_list_region.zx, character_toolbar.zx): state the truth - nested handle bump = renderAll fallback (reactivity.zig:214), focus survives via vdom diff (phase-0 gate asserts it). keep `bumpCharacterList` (intent survives; becomes real if ziex grows instance mounts). NO 4th CSR region: a drawer opened at runtime has no SSR marker, cannot hydrate (rerender-scoping note) - promotion is structurally impossible, same reason per-message components are.
- D5 delete the WebAssembly.instantiate/instantiateStreaming monkey-patch in custom.js init; trust `started.source.instance` (already authoritative), keep the `__zx_alloc` presence check as the fail-fast.

- D6 (recheck) `ui.getStoredMotion` leaks its callAlloc string (bridge.bootInit:168 never frees; handlers.zig caller dies in D3). surviving caller dupes-or-frees; one-shot boot leak, fix while touching bootInit.
- process: manager in-main (mechanical), gate re-run, one commit.

## OUT OF SCOPE (named so absence != missed)

- send loop: composer send/stop buttons unbound, `sse_start` env fn deleted in D2 - chunk-2 feature, re-enters w/ its own plan. NOT a regression.
- `zig-pkg/` dir: gitignored, referenced by nothing (deps come via the `.ziex` path dep) - zig cache artifact, no action.
- syncReadingAria's imperative aria-pressed vs vdom re-render: pre-existing deliberate CSS/DOM-side design (reading prefs hold no zx state); phase-0 gate asserts it survives a Shell re-render, escalate only if red.
- devserve.py stays: serves the exported prod-shaped dist + API proxy; ziex `serve` runs the SSR app, a different artifact. deliberate split.

## PHASE 3 - Q1 DATA LAYER TO ZIG (decision: REC yes, own chunk)

goal: kill the JS parallel store (`jsCharacters`, `personas`, `selectedPersona`, `csrfToken` in custom.js) - ZX7 says Zig owns authoritative state. today the glue is a second source of truth reached back into by index.

- new `app/pages/net.zig` (zx-importing): thin wrapper over ziex client fetch (`fetchAsyncCtx`, runtime/client/fetch.zig:70 - callback+ctx, 64-slot registry, buffered responses) w/ csrf header injection. csrf token fetched once at bootInit, held in Zig.
- new `app/pages/char_api.zig`: characters/all, settings/get (personas + clientReadingPrefs), chats/get, characters/{create,rename,duplicate,delete,edit-attribute} -> `std.json` parse (Z97 Parsed lifetime: parse w/ alloc_always into the store's allocator, deinit after copy) -> char_store/persona_store/store writes -> region bumps. replaces fetchCharacters/fetchPersonas/loadCharacterChat/charApiPost in custom.js.
- stays door-side (browser-API-bound, thin): file upload (import, avatar - FormData w/ File), blob download (export), `prompt`/`confirm` (callable via js.global reflection from Zig - move them too, they work). SSE pump stays (ziex fetch has no streaming).
- bridge exports `__st_add_character`/`__st_set_character_meta`/persona adders become internal fns (door no longer feeds data) - keep exports only for the phase-0 gate's injection path (gate uses them) w/ a comment.
- DESIGN-PROBE first (rule gate: new module + interface, substantial): member in throwaway worktree implements the riskiest slice - fetchAsyncCtx callback ctx lifetime + std.json parse of characters/all + store handoff + rerender from a fetch callback (is rerender safe off the event loop tick? probe answers) - revert, friction report, then real build.
- process: member in worktree (substantial), lead verifies vs gate + browser, T-tier normal.
- size: net.zig+char_api.zig new (~2 modules), custom.js shrinks ~300 ln, bridge slims, settings-save moves in (B6 hook).

## PHASE 3b - REMAINING DECISIONS

- Q2 zx.kv for localStorage: REC SKIP for now. costs: `feat_kv_client` build opt + door kv bindings at init + `ziex-kv:default:` key-prefix migration of st-reading-*/st-motion; buys a namespaced api over 3 surviving reflection call sites. revisit if pref surface grows or ziex kv leaves Alpha.
- Q5 rules promotion: run `/promote-rule` x3 -> ZX11 (T1 currentTarget), ZX12 (T2 literal names), ZX13 (T3 bare root allocator) into webdesign-ziex.md. wiki note already links them.

## ORDER + GATES

-1 commit pending tree [done, other agent] -> 0 confirm+gate [done 941476b19] -> 1a F0+B4+B8 [done 3239961d6] -> S1 probe [done, minor] -> S2 Z-DATA/BOOT/DIALOG [in flight, m-zigdata] -> S3 B-wave in Zig -> S4 door slim+split -> S4b tailwind adoption (operator pick B) -> S5 leftovers -> 3b rules. (zig-maximal directive 2026-07-14 folds the old 1b/2/Q1 into S1-S5.) deploy to sillybeta ONLY on explicit ask (standing memory). every phase: `zig build` + `zig build test` + `zig build check` + verify.sh both stages.

## RELATED

- [bug register 2026-07-10](bug-register-2026-07-10.md) - prior findings corpus; this plan supersedes nothing there, adds the 2026-07-14 cluster.
- [ziex refactor plan](ziex-refactor-plan.md) - region/memo design the fixes must not regress.
- [reading surface spec](tier1-reading-surface-spec.md) - the feature B1/B6 make functional again.
