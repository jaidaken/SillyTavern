---
description: Complete consolidated register of every bug/issue/fault found across all audits of the WASM/Zig client (SillyTavern rebuild). Merges the W05 exhaustive audit (5 members, 235 findings, all lead-verified) with the prior 2026-07-10 backlog and the resolved Phase 0 fixes. One line per finding; the per-area W05 files carry the paragraph-length detail.
tags: [audit, register, client, wasm, zig, ziex, css, glue, a11y, security, memory-leak]
date: 2026-07-10
---

# Complete bug/issue register (2026-07-10)

Every finding across all audit passes of the `client/` WASM+Zig rebuild, consolidated. Severity: BUG =
wrong / breaks behaviour or security. DRIFT = doc/comment disagrees with code. NIT = cosmetic / latent /
hardening. QUESTION = needs an operator decision. LEAK = memory not freed (called out separately because
they compound with conversation length). Source column: which audit found it.

Detail lives in the per-area files: [glue](audit-w05-glue.md), [css](audit-w05-css.md),
[scripts](audit-w05-scripts.md), [ziex](audit-w05-ziex.md), [zig](audit-w05-zig.md), and the prior
[backlog](audit-2026-07-10.md). Refactor design: [ziex-refactor-plan.md](ziex-refactor-plan.md).

Totals: W05 = 243 (glue 28, css 65, scripts 67, ziex 34, zig 49 - zig grew from 41 after an a11y re-sweep:
22 BUG / 2 DRIFT / 23 NIT / 2 Q). Prior backlog ~40 triaged. Phase 0 = 8 resolved. Grand distinct total
after de-dup of convergences: ~278 open items + 8 resolved.

## Convergences (found independently by 2+ members = highest confidence)

- LEFT-DOCK #center REPLACE: aud-ziex (vdom.zig:415) + aud-zig (chat.zx:11). Opening any left dock destroys
  and rebuilds the whole chat log + composer (loses composer text, caret, focus, scroll). Region
  decomposition fixes it. CONFIRMED live UX bug.
- NESTED <main> + suppressed landmarks: aud-css (#31) + aud-zig (chat.zx:15, page.zx:3) + lead context.
- NO <h1> anywhere: aud-css (#32) + aud-zig (cross-cutting).
- cacheGet is not free: aud-zig (html.zig:107) confirms the memoization measurement caveat.

## Resolved (Phase 0, committed fcec85934 / 12597b70f / bab3a3628, NOT re-counted)

1. glue/main.js instantiateStreaming brick -> robust export capture. 2. class-remap split(' ') ->
split(/\s+/). 3. flush throw latches stream -> catch + reader.cancel. 4. appendMessage n+b leak on throw ->
adopted flag + finally. 5. panel-resize drag leak -> pointercancel + setPointerCapture. 6. composer
focus-ring outline:none -> :focus-visible fix. 7. stream.zig [DONE] non-termination -> saw_done + end().
8. markdown LATEXMATHSPANS -> flag removed. (Also this session: SSE extractor wired, parsePayload OOM
propagation, env.sanitize fail-closed, [DONE] glue termination, bridge __st_stream_done.)

NOTE: the backlog still lists items 7 (stream.zig:141) and 8 (markdown.zig:22) as OPEN in its "Real bugs"
list; aud-zig DRIFT flags both as already fixed. The backlog is stale on those two only.

---

## SECURITY (fix in W0; one decision for the operator)

- [BUG] G5 glue/main.js:65-72 - MESSAGE_CONFIG keeps `id` + `data-*` at DOMPurify defaults; classes are
  namespaced to `custom-` but ids/data-attrs are not, so a model-authored message `<button
  data-motion-set="off">` or `id="send_textarea"` or `id="probe-metrics"` hijacks the app's delegated
  listeners (main.js:400,412,301). Fix: `ALLOW_DATA_ATTR:false` + `SANITIZE_NAMED_PROPS:true`. CONFIRMED.
- [QUESTION] G21 glue/main.js:70-71 - FORBID_TAGS lists only `style`; DOMPurify defaults leave
  form/input/button/select/textarea renderable with off-origin http(s) `action`, and the hook stamps
  target=_blank. A model message can draw a credential prompt that posts off-origin. BUG vs upstream-parity
  is the OPERATOR's call.
- [BUG] unit_test.zig:389 - the SanitizedHtml witness-forgery scanner reads .zx ONLY; a .zig file in
  app/pages/ can forge a witness (html.zig admits the witness is forgeable, no field privacy) and reach
  @escaping={.none}. Extend the scan to *.zig.
- [QUESTION] unit_test.zig:93 - `matchRawAttr` matches only literal `@escaping={.none}`; a non-literal
  spelling is uncounted while `total==1` still passes. Does the ziex parser accept a non-literal there?
- [BUG] stream.zig:36 - `line` has no size cap; a peer that never sends `\n` grows it until the wasm heap
  dies (untrusted-network boundary). completion.zig:29 unbounded parseFromSlice compounds it.
- [BUG] server/render.zig:79 (build-time, latent) - `.text` under escaping==.none is html-unescaped, so
  server/client disagree on bytes; shielded today only because html.zig:22 SSRs a placeholder.
- [QUESTION] G22 glue/main.js:131 - highlightBlocks does an innerHTML round-trip DOMPurify warns can
  resurrect mutation XSS; no working vector found; safer shape = RETURN_DOM_FRAGMENT + highlight + serialize.
- [NIT] G16 glue/main.js:394 - `MOTION[name] != null` reaches Object.prototype; `data-motion-set="toString"`
  passes the null check; also persists any string to localStorage first. Use null-proto or Object.hasOwn.
- [NIT] devserve.py:128-131 - forwards Cookie/Authorization to an unvalidated --backend (loopback-bound).
- [NIT] devserve.py:24 - `/csrf-token` prefix match + urljoin could network-path-reference; add `//` guard.

## CORRECTNESS BUGS

### Streaming / store
- [BUG] chat.zx:11 (CONVERGED) - left-dock toggle REPLACEs #center: chat + composer destroyed, scroll/caret
  lost, every message node rebuilt. Root cause vdom.zig:415 + Transpile.zig:1658 empty-fragment collapse.
- [BUG] stream.zig:68 - post-[DONE] tokens in the SAME feed chunk are appended + counted; doc says ignored.
  end() has the same shape. glue coalesces a frame's chunks into one feed, so it is reachable.
- [BUG] G4 glue/main.js:273 - __st_stream_begin returns void; bridge.zig:42 swallows begin failure; glue
  sets begun=true anyway, fetches, flushes into a non-.streaming stream -> silent no-op, network with no
  message, tokens=0. Needs a status return.
- [BUG] bridge.zig:32 - appendMessage swallows alloc failure silently (message vanishes, no console/screen).
  Same shape bridge.zig:42 streamBegin.
- [BUG] html.zig:95 - a body that sanitizes to empty ("" from adopt) is never cached, so quote+md4c+DOMPurify
  re-run every render forever. adopt conflates failed-dupe and legit-empty.
- [DRIFT] G7 glue/main.js:191 - startStream hardcodes 'Seraphina' as the speaker for every SSE message.

### The throw-into-wasm chain (transient, heap-exhaustion trigger)
- [BUG] G1 glue/main.js:187 - `return writeString(out)` sits outside the sanitize try/catch; writeString
  throws on __zx_alloc null, unwinding into the wasm door past every Zig defer. The comment says this path
  never happens; it does. CONFIRMED.
- [BUG] G2 glue/main.js:53-59 - via G1: a throw after store.append ADOPTED the buffers skips adopted=true, so
  finally frees n+b while Store still owns them -> double-free + UAF next render.
- [BUG] G3 glue/main.js:243 - via G1: door buffer leaks past bridge.zig:56 defer; streamBegin unwind strands
  stream_index set + state .streaming with no message.
- [BUG] G6 glue/main.js:138 - `growing` treats a process-wide streamRender flag as message-scoped; a cache
  miss inside a stream frame (failed-sanitize-not-cached html.zig:95, or a Wyhash collision html.zig:102)
  skips an innocent settled message's last code block, then cachePut stores the un-highlighted HTML for the
  page's life. Persistent, not transient.

### ziex render engine (all app-exposed unless noted)
- [BUG] vdom.zig:53-94 - double-free on OOM (errdefer armed after explicit destroy). Latent (OOM only).
- [BUG] Client.zig:281-284 - dispatchEventByName calls dispatchEvent with wrong arity; dead + would not
  compile if referenced.
- [BUG] Client.zig:336-347 - render inserts vtree before createPlatformNodes/replaceContent; on failure the
  map keeps an unmounted vtree and the next diff patches nonexistent DOM. Latent (OOM), silent (catch{}).
- [BUG] x.zig:95,102,206 + Component.zig:78,84 - alloc failure = @panic("OOM") = wasm trap, uncatchable.
- [BUG] Transpile.zig:1752,1904,1925 - `{for}` emits `alloc catch unreachable`; ReleaseSmall makes
  unreachable UB, N grows with conversation.
- [BUG] App.zig:100-103 - kv_wasm stack local stored into global zx.kv vtable = dangling. Latent (kv off).

### App Zig / .zx logic
- [BUG] ui.zig:78 - onDrawer reads event.target not currentTarget; works only because buttons have no child
  elements; the first child (svg/badge) silently breaks every drawer.
- [BUG] sanitized.zig:52 - beginSse + sse_start extern are dead but the extern pins a live env import.
- [DRIFT] G8 glue/main.js:369 - resize clamp duplicates ui_state min/max; can silently disagree.
- [DRIFT] G9 glue/main.js:250,298,381 - three inconsistent policies for calling mandatory exports; guard
  turns a missing export into a silent no-op. Assert the export set once at boot, call unguarded.

## MEMORY LEAKS (ziex-side; land with the W2 patch. App's own Zig core is CLEAN per aud-zig verdict.)

- [LEAK/BUG] vdom.zig:381 concatRawText - BIGGEST. Leaks both buffers per diff of an @escaping={.none}
  element; every mes_text is one; per token leaks ~2x total on-screen sanitized HTML. Fix = toOwnedSlice +
  free the patch. Memoization reduces frequency; streaming message still needs the fix.
- [LEAK/BUG] Client.zig:331 never-freed render tree - COUPLING HAZARD: the leak masks a UAF (patched vtree
  adopts newest pointers); freeing needs a ONE-RENDER GRACE (like sanitized.renderTick). Constrains W2.
- [LEAK/BUG] vdom.zig:655 componentOwnerId - 2*(3+N) allocPrints leaked per frame, grows with conversation.
- [LEAK/BUG] vdom.zig:393 flattenComponents - result slice never freed; >=2 per render.
- [LEAK/BUG] Client.zig:316 Document.init - one jsz handle leaked per render.
- [LEAK/BUG] Client.zig:252 handler_registry never pruned - grows per panel close / left-dock REPLACE.
- [LEAK/BUG] Client.zig:272 dispatchEvent - event_ref handle never released, per drawer click. (ui.zig:77
  doubles it app-side.)
- [LEAK/BUG] render.zig:204 createPlatformNodes - drops the jsz handle for every node; pins detached DOM.
- [LEAK/BUG] document.zig:287 clearContent - one handle leaked per removed node (hydration).
- [LEAK/NIT] reactivity.zig:133 getOrCreate id_copy on put-fail (State unused); render.zig:188
  formActionCallback (forms unused); server/render.zig:19 renderScript success path (build-time).
- [NIT] Client.zig:305 unused Console per render; :240 redundant _setEventHandlerMode per render (~10x);
  :328 current_render_id never cleared.

## DEAD CODE / DRIFT

- [BUG] app.css .mes_code (:504), --accent-dim/--text-xl/--s-1 (:34,50,57 zero consumers), .composer-btn
  transition (:614 redefined :665). css #61-63.
- [DRIFT] .composer-btn.is-stop (composer.zx:8) has no rule; composer shows 3 buttons + 2 states at once.
- [NIT] #chat-root (page.zx:3) no rule; IBMPlexSans-600.woff2 one accidental <th> consumer.
- [NIT] G12/G13 glue class allowlist keeps dead fa-/note-/monospace + 46 hljs-* selectors reachable from
  message content (contradicts the only-themes-may-style invariant).
- [BUG] README.md:20 documents bare `zig build` (ships unpatched door); :63 claims per-message client
  components (impossible, contradicted 2 screens down); :9,:93 stale chunk notes; scripts absent from layout.
- [NIT] fixtures.zig sections[1..] + messages[3] ship in the wasm unused.
- Backlog dead-code items (glue dev/probe block :368-402, always-on stats, window.* globals, motionPrefFromStr,
  demo convo in ChatView) - all still open, all [FIX].

## CSS / DESIGN (65 findings; distinctiveness gate FAIL, localised to chrome)

- [BUG] colour: --st-quote == --accent (#1), --st-em == --muted (#2), .mes_text a unstyled UA blue (#3),
  hljs theme stock GitHub Dark cool-in-warm (#4,#5), --border 1.44:1 as control boundary (#6).
- [BUG] type: synthetic bold/oblique on IBM Plex Mono (#11), @font-face no metric-matched fallback -> CLS
  (#12), .composer-input ~290ch no max-width (#14).
- [BUG] spacing: .panel-resize clipped to 5px by .panel overflow:hidden (#20), zero @media breakpoints, bar
  collides <360px, dock squeezes chat to 0 (#21).
- [BUG] motion: `system` pref still paints "System" active under OS reduce, no resolved-state indication (#27).
- [BUG] a11y: nested <main> (#31), no <h1> (#32), --muted APCA Lc 39.5 (#33), --faint Lc 21.4 fails WCAG AA
  (#34), --st-em Lc 40.2 primary reading prose (#35), .panel-resize pointer-only aria-hidden (#36).
- [BUG] distinctiveness: accent spent 9 ways (#51), declared diamond signature is a UI-kit bullet (#52),
  12 Feather icons = component-library motif (#53), IBM Plex superfamily no contrast (#54), swap-the-logo
  chrome passes as a generic dev tool (#55), AI-default cluster 2 near-black+one-accent (#56), stock copy
  "Type a message..." + dev-note empty state (#57).
- [DRIFT/NIT] #37-50, #58-65: composer <footer> not contentinfo, topbar <header> not banner, hljs italic
  synth, list indent mismatch, img no aspect-ratio, 6 ID selectors defeat theming, 671-line monolith, brief
  has no rejected second direction, plus the dead-CSS above. Full list in the css file.

## SCRIPTS / BUILD / DEPLOY (67 findings)

- [BUG] devserve.py:96 SSE shape (bare text, completion.zig:25 rejects) -> 0 tokens; :147 buffers whole
  proxied response (real streaming never exercised); :134 no timeout.
- [BUG] verify.sh: 15 checks RED on a clean tree (stale demo assertions) + 7 checks VACUOUS-GREEN (hostile
  fixtures no longer rendered, so a sanitizer regression sails through) + :55 asserts marker absence which
  patch-door.sh documents as insufficient + :48 hardcoded chrome no existence check + :39 never checks
  main.wasm + never runs `zig build test`/`check`.
- [BUG] build.sh:12 never runs test/check/prune-dist; :14 prune-dist never invoked (ships unpruned tree).
- [BUG] setup-ziex.sh:32 applies 01/02/04 only; patch 03 applied by NOTHING (patch-door.sh reimplements it
  as hardcoded literals, no equivalence check; README claims all four applied).
- [BUG] prune-dist.sh never called + KEEP unverified after prune + DIST=".." unguarded.
- [BUG] dev-tunnel.sh:10 no ExitOnForwardFailure -> silent dead tunnel.
- [QUESTION] no deploy script in the tree; tar-over-ssh is an unrecorded manual step; nothing proves the
  deployed bytes came from the patched build. + fixed-order export/patch-door/prune is human memory.
- ~40 NIT/DRIFT: header forwarding, param validation, encoding, glob safety, README staleness, build.zig
  edges (NDEBUG on the test build defeats md4c asserts, check never run, target-options on the test module).

## PERFORMANCE (distinct quadratics beyond the known one)

- [BUG] quotes.zig:199 paragraphEnd called per `<` and per backtick run inside one wrap -> O(n^2) per body.
- [BUG] html.zig:107 cacheGet full-body hash + memcmp per hit -> render cache is O(total chat bytes)/render,
  NOT free. The Phase 1 memoization measurement must account for it.
- [DEFER, backlog] quotes.zig full-body re-wrap per stream frame (multiplies on top of the above);
  libc_shim resize always alloc+copy; utf8 flush zero-length alloc.

## TEST QUALITY (4 BUGs, aud-zig)

- [BUG] completion.zig - the untrusted-JSON parser has NO alloc-failure and NO fuzz test (every sibling has
  both; testing.md requires it for untrusted input).
- [BUG] markdown.zig:125 - `never_panics_on_random_bytes` asserts nothing, discards result, 21-char ASCII
  alphabet (no UTF-8/NUL despite the streaming path feeding UTF-8).
- [BUG] quotes.zig:477 - property test asserts round-trip only, never the headline "no <q> inside code".
- [BUG] html.zig:49 - adopt (the u64->slice door decode) has zero coverage; split the pure decode out.

## VENDOR / SUPPLY-CHAIN (provenance verified clean)

- DOMPurify 3.4.11 (current latest, unmodified upstream, hash recorded), highlight.js 11.11.1 (current
  latest, vendor-hljs.py reproduces byte-for-byte). Both lack an SRI/lockfile record: [NIT] G24/G26. hljs
  bundle 378KB raw = 4.9x the wasm (G25). markdown-it-imsize unmaintained (prior note).

## ACCESSIBILITY (consolidated; W05 + backlog)

nested <main>, no <h1>, no landmarks (banner/contentinfo suppressed by the <main> mount), no aria-live on
the message log, no aria-busy on the streaming message, no skip link, drawer overlay not inert (background
reachable), resize handle pointer-only + aria-hidden, composer textarea no name/label, settings note not
associated, duplicate title+aria-label announcements, motion control shows preference not resolved state.
Backlog a11y [FIX] items (radiogroup, aria-expanded/controls, aside labels, type=button, disable inert
buttons, meta color-scheme) all still open.

## Original backlog items still open (not superseded by W05)

Feature: per-speaker colour [DEFER unit]. Perf: quotes sealed-prefix cache, libc_shim in-place resize, utf8
zero-alloc flush. Monolithic: glue/main.js split, app.css layer split. Zig nits batch: store doc-gaps +
shared page-allocator const, quotes hardcoded refs, completion.zig tokenText pyramid flatten, html/sanitized
filename inversion, bridge.zig alias comment, unit_test known_zx_count=8 (should be 10), ui.zig two-globals
+ drawerClass redundant param + default_width not re-exported. ACCEPT items: ui_state linear scan (N=9),
qsort shellsort, intCast note, digit-led ordered list.

## Addendum 2026-07-10 (wave-1 integration findings)

- [OPEN] Lone streamed code fence never highlights. A single fenced code block that arrives while
  streaming is skipped by the growing-block highlight skip, and once the message settles the
  memo-reconcile skip (patch 06) means MessageView never re-renders it, so `highlightBlocks` never runs
  on the sealed block. Found by m-gate (verify.sh needed a 2-fence payload to get any hljs spans). A 2+
  fence message DOES highlight; only a lone fence stays plain. Fix candidate: force one highlight pass on
  stream-seal (bypass the memo skip for the sealing message), or run hljs on settle regardless. Client bug.
- [FIXED this wave, commit pending] onDrawer read `currentTarget`, which ziex nulls before it calls the
  Zig handler (handler runs after native dispatch ends), so every drawer/dock button toggled nothing.
  Introduced by m-zigcore, caught by the render-harness toggle checks (dockOpened false, shell delta 0),
  reverted to `target` (safe: the button is empty, icon is a ::before pseudo). ui.zig onDrawer.
