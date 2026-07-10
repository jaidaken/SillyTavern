---
description: W0.5 exhaustive audit synthesis (5 read-only members, disjoint surfaces, all lead-verified). Elevates the load-bearing findings + convergences + security + plan impact over the 235 raw findings in the per-area files.
tags: [audit, wasm-zig-client, ziex, security, memory-leak, a11y, plan]
date: 2026-07-10
---

# W0.5 exhaustive audit synthesis (2026-07-10)

Five read-only tmux members, disjoint surfaces, shared tree at 5be4f1638 (client/ byte-identical to
bab3a3628; the newer commit touched only public/). Each returned a findings file; the lead spot-verified
every load-bearing claim against source before trusting. Raw findings (235 total) live in the per-area
files; this doc elevates what drives W0-W2 + the security decisions.

## Per-area files + counts (all lead-verified)

- glue JS: `audit-w05-glue.md` - 28 (6 BUG / 3 DRIFT / 16 NIT / 3 Q). Zig<->JS binding cross-check CLEAN.
  Vendor provenance re-derived: DOMPurify 3.4.11 + highlight.js 11.11.1, both unmodified upstream.
- CSS: `audit-w05-css.md` - 65 (28 BUG / 5 DRIFT / 20 NIT / 3 Q / 9 PASS). Distinctiveness gate FAIL.
- scripts/build/deploy: `audit-w05-scripts.md` - 67 (16 BUG / 12 DRIFT / 36 NIT / 3 Q).
- ziex subsystems: `audit-w05-ziex.md` - 34 (19 BUG / 1 DRIFT / 12 NIT / 2 Q). 17 app-exposed. Reachability
  confirmed against the 22-import table of dist main.wasm.
- app Zig + .zx: `audit-w05-zig.md` - 49 (22 BUG / 2 DRIFT / 23 NIT / 2 Q; grew from 41 after an a11y
  re-sweep found 8 more: no heading element anywhere, no skip link, drawer overlay leaves background
  tab-reachable, aria-busy must land with the message-log live region). Memory-safety verdict: the app's own
  Zig core is CLEAN (no UAF / double-free / leak); every leak is ziex-side.

## Convergences (found independently by 2+ members = highest confidence)

- LEFT-DOCK #center REPLACE: aud-ziex (finding 3) + aud-zig (finding 1). Opening a left-side dock
  (ai_config/connections/formatting/world_info/settings/backgrounds) shifts `div#center` in `chat.zx`'s
  `#content` child list, and because an else-less `{if}` transpiles to an empty fragment that
  `flattenComponents` drops (no key slot held), `reconcileChildren` diffs `#center` against the new
  `aside`, tag mismatch -> REPLACE destroys and rebuilds the WHOLE chat log + composer: composer text,
  caret, focus, and scroll position all lost; every message node recreated. Right docks append after
  `#center` and cost one cheap PLACEMENT. LIVE UX BUG, not just perf. Region decomposition (W2) fixes it.
- NESTED <main>: aud-css + aud-zig + lead context. `page.zx:3` `<main id="chat-root">` wraps `chat.zx:15`
  `<main id="chat">`: two landmarks, suppresses banner/contentinfo roles on topbar/composer, no `<h1>`.

## Security (W0 fixes + one decision for the operator)

- [W0] G5 sanitizer gap (glue/main.js MESSAGE_CONFIG, CONFIRMED end to end): message content keeps `id`
  and `data-*` (only classes are namespaced to `custom-`), and the app's delegated listeners key on
  `[data-motion-set]` (main.js:400) and `id === 'send_textarea'` (main.js:412). A model-authored message
  body hijacks the app's own controls. Fix: `ALLOW_DATA_ATTR:false` + `SANITIZE_NAMED_PROPS:true`.
- [DECISION] G21 model-authored forms: DOMPurify defaults let a message render `<form>`/`<input>`/`<button>`
  with an off-origin http(s) `action`, and the afterSanitizeAttributes hook stamps target=_blank+noopener.
  A model message can draw a credential prompt that posts off-origin. BUG vs upstream-parity intent is the
  operator's call. Single-user beta behind Pocket-ID lowers but does not remove the risk (malicious char
  card / compromised model output).
- [W0/W2] witness scanner gap (unit_test.zig:389): the SanitizedHtml forgery scan reads .zx sources ONLY;
  html.zig's own header admits the witness is forgeable and Zig has no field privacy, so any .zig in
  app/pages/ could forge a SanitizedHtml and reach `@escaping={.none}`. Extend the scan to *.zig.
- [W0] stream.zig:36 unbounded `line` (untrusted-network boundary): a peer that never sends `\n` grows the
  buffer until the wasm heap dies; completion.zig unbounded parseFromSlice compounds it. Add a cap.

## Correctness bugs (W0, verified)

- stream.zig post-[DONE] same-chunk append (aud-zig 2): drain emits complete lines after `saw_done` is set
  before feed seals, so tokens after `[DONE]` in one animation-frame chunk get appended + counted. Doc
  says they are ignored; they are not.
- html.zig:95 empty-sanitize never cached: `adopt` returns "" for both a failed dupe AND a legit empty
  DOMPurify result, and `Cache.put` refuses to store "", so a body that sanitizes to nothing re-runs
  quote-wrap + md4c + DOMPurify every render forever.
- devserve.py:96 SSE shape + verify.sh (15 red checks + 7 VACUOUS-GREEN): the vacuous-green is the sharp
  one - 7 assertions pass because their hostile fixtures are no longer rendered, so a sanitizer regression
  sails through. W0 must restore real adversarial inputs, not just retune numbers.

## Leaks (ziex-side, land with the W2 patch)

- concatRawText double-leak (vdom.zig:381, BIGGEST): leaks both buffers on every diff of an
  `@escaping={.none}` element; every message's mes_text is one; per streamed token leaks ~2x the total
  sanitized HTML of all on-screen messages. Fix `toOwnedSlice` (capacity != written len, so free is wrong
  length). Memoization reduces it (unchanged messages skip the diff) but the streaming message still needs
  the fix.
- never-freed render tree (Client.zig:331) - COUPLING HAZARD FOR W2: the abandoned per-render Component
  tree currently MASKS a UAF, because the patched vtree adopts the newest render's pointers; freeing at
  end-of-render resurrects the crash. A correct free needs a ONE-RENDER GRACE (diff reads render N-1's
  children before adopting render N) - the same discipline sanitized.renderTick already uses for the app's
  own HTML. W2 must honor this or it reintroduces D2.
- 4-site jsz handle leak (render.zig createPlatformNodes, Client.zig Document.init + dispatchEvent,
  document.zig clearContent): removed DOM nodes never GC'd; handler_registry never pruned (grows per panel
  close). {for} emits `alloc catch unreachable` = UB under ReleaseSmall, N grows with the conversation.

## Plan impact (folded into the DESIGNED PLAN)

1. W2 memoization gains a hard constraint: it lands alongside the tree-free fix, which MUST use a
   one-render grace (Client.zig:331 UAF hazard). The dead propsPtr short-circuit (vdom.zig:188, dead
   because components resolve eagerly and the node is never stored as .component_fn) confirms the memo must
   be added at the reconcile level before resolveComponent, as designed.
2. Region decomposition (W2) now fixes a CONFIRMED live bug (left-dock #center REPLACE), not just structure.
3. cacheGet is NOT free (html.zig:107 full-body hash + memcmp per hit): the memoization before/after
   measurement must account for it, not assume the cache is zero-cost.
4. W0 expands from "fix the regression gate" to also cover the security fixes (G5, stream cap, witness
   scanner) + the correctness bugs (left-dock is W2/region, post-[DONE], empty-cache), because they are in
   disjoint code from the reactive work and give a clean, secure baseline before W2.

## Perf (Phase 7, distinct from the known quotes O(n^2))

- quotes.zig paragraphEnd called per `<` and per backtick run inside one wrap (:199).
- html.zig cacheGet full hash + memcmp per hit (:107).

## Index of raw files
- [glue](audit-w05-glue.md) [css](audit-w05-css.md) [scripts](audit-w05-scripts.md) [ziex](audit-w05-ziex.md) [zig](audit-w05-zig.md)
