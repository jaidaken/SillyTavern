---
description: Deep design document for the ziex reactive-model refactor of the WASM/Zig client. The render mechanism as it actually works, the design-probe MAJOR result, the memoization + region-decomposition design, the constraints the W05 audit put on it, rejected alternatives, and the test plan.
tags: [ziex, refactor, reactivity, vdom, memoization, wasm, zig, design]
date: 2026-07-10
---

# Ziex reactive-model refactor: design

Standalone design for the refactor formerly called "Phase 1". Grounded in a full read of ziex @ 26f5945
(`.ziex/src`: x.zig, runtime/client/{Client,render,reactivity}.zig, runtime/client/window/document.zig,
runtime/core/vdom.zig, runtime/server/render.zig, core/Transpile.zig) and the app layer, plus a disposable
design-probe and the five-member W05 audit. Companion: [bug-register-2026-07-10.md](bug-register-2026-07-10.md).

## 1. The problem as originally framed

The whole client is ONE client-rendered component. `page.zx:3` mounts `<ChatView @rendering={.client} />`;
`chat.zx` renders the topbar, side panels, the entire message list (`{for} <MessageView/>`), and the
composer. Every state change (`bridge.zig` on a streamed token, `ui.zig` on a panel toggle) calls
`zx.client.rerender()`. The original Phase 1 goal: make each message its own re-renderable component so a
streamed token re-renders only the streaming message, not all N.

## 2. How ziex actually renders (the mechanism)

- `rerender()` (`reactivity.zig:204`) unconditionally calls `client.renderAll()`. It is the ONLY public
  reactive entry point; `scheduleRender` is a private const, only `rerender` + `State` are re-exported.
- `renderAll()` (`Client.zig:301`) loops `self.components` - a COMPILE-TIME registry the transpiler builds
  from every `@rendering={.client}` site (`Transpile.zig:1053`) - and calls `render(cmp)` on each.
- `render(cmp)` (`Client.zig:313`): finds the DOM comment marker `<!--$id-->` (`findCommentMarker`,
  TreeWalks body), calls the component fn (props re-parsed from the marker ZON), then EITHER hydrates
  (first render: build vtree, createPlatformNodes, `marker.replaceContent`) OR diffs the new vtree against
  the stored one and applies granular patches.
- The DIFF is granular (`vdom.zig` diff + reconcileChildren, a full React-style keyed reconciliation). For
  a streamed token only the streaming message's `mes_text` differs, so exactly ONE `RAW_HTML` patch is
  emitted (`vdom.zig:283`). Unchanged messages and the shell emit no patch.
- `scheduleRender(id)` (`reactivity.zig:214`) renders exactly ONE registered component; it falls back to
  `renderAll()` for any id not in the compile-time registry.
- `State(T).set()` (`reactivity.zig:100`) calls `scheduleRender(self.component_id)`, where `component_id`
  is the enclosing component's id (set via `current_render_id`). This is the intended scoped-reactivity
  path. The app does not use it; it uses the module-global-var + `rerender()` pattern.

## 3. The design-probe MAJOR result (per-message client components are not viable)

A disposable probe (member, throwaway worktree, reverted) built the per-message-CSR slice and measured it.
Verdict MAJOR, lead-verified against source:

- `@rendering={.client}` is a NO-OP on the client build (`x.zig:543`): a nested client component is inlined
  into the parent vtree, no independent render boundary.
- Client components hydrate ONLY from a server-emitted `<!--$id-->` marker. A message that arrives at
  runtime (streamed) has no marker, and `store.slice()` is empty at SSR, so streaming messages are exactly
  the un-markable ones. No `mount`/`hydrate`/`createRoot` API exists.
- Component ids are per-JSX-SITE not per-instance (`Transpile.zig:42` md5 of name+path+site-index): a
  `{for}` of N messages shares ONE id, N instances collapse to one vtree slot.
- `store.Message` cannot even be a client-component prop: props route through zxon which yields
  `[]const u8`, a hard compile error against `Message.{name,body}_owned: ?[]u8`.
- `component_subscriptions` (`reactivity.zig:31`) is a dead stub.

Conclusion: the framework simply does not support per-message runtime components without major core
surgery. The plan changed. What follows is the redesign.

## 4. What the cost actually is (the reframe)

Measured + audited, the whole-page render is NOT expensive at the DOM layer: ~1 DOM write per token
regardless of chat length. The cost is CPU, and it has three parts, all O(N in messages) per token:

1. `reconcileChildren` (`vdom.zig:465`) eagerly `resolveComponent`s EVERY child before diffing, so all N
   `MessageView` fns run every token (even sealed ones). The render cache makes each cheap-ISH but not free.
2. The render cache is NOT free (aud-zig, `html.zig:107`): `cacheGet` hashes the whole body + a full memcmp
   per hit. So even a cache hit is O(body length) per message per token.
3. `concatRawText` (`vdom.zig:381`) LEAKS both buffers on every `@escaping={.none}` diff, and every
   `mes_text` is one. Per token this leaks ~2x the total sanitized HTML of all on-screen messages (the
   single biggest leak in the codebase, aud-ziex). It also does the concat+eql O(N) work.

All three grow with conversation length AND per-message richness (the colour/avatar/markdown phases add to
each message). This is why "measure first, maybe it is fine" was wrong: the cost provably compounds.

## 5. The design

Two changes, both in Zig/ziex, no new JavaScript, no glue-side DOM hack.

### 5a. Memoization (the actual per-token cost fix; React.memo equivalent)

Teach `reconcileChildren` to skip a child whose identity + content are unchanged BEFORE it calls
`resolveComponent`, so `MessageView` is not even invoked for a sealed message.

- The skip key is cheap and correct because the store guarantees a SEALED message's body pointer is stable
  and immutable for the life of the page (`store.zig` endStream: remap-or-keep, never moves after seal).
  So "same message key + same body pointer = unchanged = skip" holds by construction. The streaming
  message (unstable body) is never skipped, which is correct.
- This requires the app to give each message a stable `key` (message sequence index) so reconcile can match
  by key, and a memo signal (the body pointer, or a sealed flag + pointer). The transpiler emits `{for}`
  children; the key rides as an attribute.
- Interaction: ziex ALREADY has a `propsPtr` memo short-circuit in `diff` (`vdom.zig:188`) but it is DEAD
  (aud-ziex), because `createFromComponent` resolves every `.component_fn` and destroys the node, so a
  VNode's component is never `.component_fn`. The memo must therefore be added at the RECONCILE level
  (before resolve), not revived at the diff level. Confirmed by the probe and the audit.
- Effect: per-token work drops from O(N messages) to O(1 streaming message). It also removes the
  concatRawText + cacheGet cost for the skipped messages (they are never touched).

### 5b. Region decomposition (code structure + cross-region scoping + a confirmed bug fix)

Split the monolithic ChatView into top-level `@rendering={.client}` components: Shell (topbar + drawers),
MessageLog, Composer, and the SidePanel docks. Each becomes its own registry entry + marker + vtree +
independent `render()`.

- Mutations move from the module-global-var + `rerender()` pattern to ziex `State`, so each scopes to its
  region via `scheduleRender(owning-component-id)`: a panel toggle re-renders only Shell, a token
  re-renders only MessageLog, a composer keystroke only Composer.
- The door (`bridge.zig`) is outside the component tree, so it cannot hold a State directly. Two options:
  (a) MessageLog publishes its State handle to a module global on first render, and the door calls `.set()`
  on it; (b) a small ziex helper `scheduleRenderByName("MessageLog")` the door calls. (a) needs no ziex
  change; (b) is ~5 lines. Decide at build time; (a) preferred (no fork surface).
- This FIXES a confirmed live UX bug (converged aud-ziex + aud-zig): today opening a left-side dock
  REPLACEs the entire `#center` subtree (chat + composer), losing composer text, caret, and scroll, because
  an else-less `{if}` collapses to an empty fragment that shifts sibling indices (`vdom.zig:415` +
  `Transpile.zig:1658`). Making Shell/MessageLog/Composer independent top-level components (each in its own
  marked region, not siblings in one `{if}`-bearing list) removes the index-shift entirely. So region
  decomposition is a correctness fix, not just cleanliness. (The empty-fragment collapse should ALSO be
  fixed at `Transpile.zig:1658` = emit `.none` not `.fragment`, as defence in depth.)

## 6. The hard constraint the audit surfaced (coupling hazard)

`Client.zig:331`: the per-render Component tree is never freed, and that leak currently MASKS a
use-after-free, because the patched vtree adopts the newest render's pointers (`vdom.zig:281,295,318`).
Any work that starts freeing the tree (which memoization touches, since skipped children must keep their
old vnodes) MUST honor a ONE-RENDER GRACE: `diff` reads render N-1's `old_element.children` before adopting
render N, so a tree can only be freed one render after it is superseded. The app already implements exactly
this discipline for its own HTML via `sanitized.renderTick()` (`html.zig` RetireRing). The ziex patch must
mirror it. Freeing eagerly reintroduces the D2 UAF. This is the single riskiest part of the refactor and is
why it gets its own design-probe (section 8).

## 7. Rejected alternatives

- RUNTIME COMPONENT MOUNTING (rebuild ziex so each message is a fully independent runtime-mounted client
  component with its own marker + a runtime-extensible registry + per-instance ids + real client-side CSR
  mounting, today a stub empty `<div>` at `render.zig:310`). It is the maximally-complete version and it
  works, but it is major surgery on the framework core for NO behavioral benefit over memoization: the
  streaming message is the only one that changes token-to-token, and memoization already isolates it.
  Reserve only if the memoization probe shows the skip cannot be made correct.
- GLUE WRITES THE STREAMING TAIL straight to the DOM node (probe option C). Fastest for streaming but adds
  JavaScript (against as-little-JS-as-possible), bypasses the framework, and desyncs the vtree from the DOM.
  Rejected.

## 8. Test plan

- ALLOC-FAILURE ORACLE: `checkAllAllocationFailures` on every allocating fn touched (the memo path, the
  tree-free path). The store + stream + html modules already have this discipline; extend it.
- MEMOIZATION MEASUREMENT (measure, do not guess): render-fn invocation counters for MessageView + each
  region, exported through the wasm door, driven headless (the probe harness already did this). Assert
  per-token MessageView invocations drop from N to 1 after the memo. Account for cacheGet cost separately
  (html.zig:107) so the before/after is honest.
- UAF GUARD: a dangerous-property test for the one-render-grace tree-free: drive N renders, assert render
  N can still read render N-1's adopted pointers, assert render N-2's tree is freed exactly once (a
  counting allocator, as html.zig's RetireRing test already does).
- LEFT-DOCK REGRESSION: headless, open each left dock, assert the composer's typed text + scroll survive
  (the converged bug). Restore the adversarial verify.sh inputs first (W0) so the gate is real.
- DESIGN-PROBE (before the real build): a disposable slice of the memoization + the one-render-grace tree
  free, run headless, measured, reverted, friction report. MAJOR result = re-plan to the operator.

## 9. Execution stages (REFACTOR-FIRST; operator chose this order 2026-07-10)

Operator elected to run the refactor before the rest of W0. The refactor carries its own minimal prereqs
(the one-line dev-stream fix + its own test harness) rather than depending on the broken `verify.sh`; the
full gate rewrite + the disjoint security/correctness bugs stay in the later workstreams. Each stage = a
visible tmux member in its own worktree; lead verifies every task against source + re-runs the oracle,
integrates, commits; members never commit. R2/R3/R4 are sequential (each builds on the prior shapes).

### R1 - DESIGN-PROBE (disposable, gates the real build)
- R1.1 member: throwaway worktree at HEAD. Implement the riskiest slice: the memoization skip in
  `reconcileChildren` + the one-render-grace tree-free (Client.zig:331).
- R1.2 measure per-token `MessageView` invocations before/after with door-exported counters, driven headless
  (the probe harness already prototyped this). Prove the UAF grace holds under a counting allocator.
- R1.3 test whether adding a `key` to `#center` + the panel slots fixes the left-dock REPLACE WITHOUT a
  transpiler patch (reconcileChildren matches by key before index) - resolves open question below.
- R1.4 revert, friction report. CLEAN/MINOR -> proceed. MAJOR -> re-plan to operator.

### R2 - Prerequisites (real, kept; low risk)
- R2.1 fix `devserve.py:96` SSE shape (one line + `import json`) so the streaming path is drivable headless.
  Verify `/dev/stream` delivers tokens.
- R2.2 fix the concatRawText leak: `vdom.zig:381` -> `toOwnedSlice`; free the RAW_HTML patch slice in
  `Client.zig:405-416` (currently frees only UPDATE). New `patches/05-concatrawtext-leak.patch`, applied by
  `setup-ziex.sh`. Independent + biggest leak; must be clean before measuring memory. Test: alloc-failure
  oracle + a counting-allocator leak test driving N renders (no growth across renders).
- R2.3 build the durable test harness: `MessageView` + per-region render counters exported through the door;
  a deterministic headless replay driver (fixed token stream, no real sleep) as the measurement + regression
  surface. This is the oracle the whole refactor is validated against.

### R3 - Memoization (the per-token cost fix; highest risk)
- R3.1 app-side: give each message a stable `key` (sequence index) + a memo signal (the sealed-body pointer;
  streaming message carries no stable signal so it is never skipped). `chat.zx` `{for}` + `message.zx`.
- R3.2 ziex patch #6 (`patches/06-reconcile-memo.patch`): `reconcileChildren` skips a keyed child whose memo
  signal is unchanged BEFORE `resolveComponent`, keeping its old vnode. NOT at the dead `diff` propsPtr
  short-circuit (vdom.zig:188). Applied by `setup-ziex.sh` after 05.
- R3.3 ziex patch #7 (`patches/07-onerender-grace-free.patch`): free the abandoned per-render Component tree
  one render late (RetireRing discipline, mirroring `sanitized.renderTick`), so skipped children's retained
  pointers stay valid. This is the UAF-coupling fix; without it the memo's kept-vnodes dangle.
- R3.4 tests: render-count measurement asserts per-token `MessageView` invocations drop N->1;
  alloc-failure oracle on the memo + free paths; a dedicated one-render-grace UAF guard (counting allocator,
  assert render N reads N-1's pointers, N-2 freed exactly once); no memory growth across a long stream.

### R4 - Region decomposition (fixes the left-dock bug; medium risk)
- R4.1 split ChatView: new top-level `@rendering={.client}` components Shell (topbar+drawers), MessageLog,
  Composer, SidePanel docks; `page.zx` mounts them as siblings, each with its own SSR marker + registry
  entry. If R1.3 showed keys alone fix the left-dock REPLACE, no transpiler patch; else ziex patch #8
  (`Transpile.zig:1658` emit `.none` not empty `.fragment`).
- R4.2 State-scoped mutations: `ui.zig` panel/motion state -> `State` owned by Shell; MessageLog publishes
  its State handle to a module global on first render, `bridge.zig` calls `.set()` on it (option a, no ziex
  change). A panel toggle re-renders only Shell; a token only MessageLog.
- R4.3 left-dock regression test: headless, open each of the 6 left docks, assert composer typed text +
  caret + scroll survive and MessageLog is not rebuilt.
- R4.4 tests: scoped-render measurement (panel toggle touches only Shell; token only MessageLog); full
  headless drive of a multi-message stream + panel interaction.

### R5 - Integrate, converge, ship
- R5.1 merge all kept patches (05/06/07 + maybe 08) + the app changes on one tree; rebuild green; run the
  FULL merged-tree suite (native `zig build test` + the headless harness), not just per-stage green.
- R5.2 convergence: self pass + a fresh-eyes `/sub audit` critic on the merged reactive change.
- R5.3 deploy to sillybeta; browser-verify (load the page, read the console, drive a stream + a panel toggle
  in a real browser). A UI change is not verified until it renders in a browser (memory: browser-verify).
- R5.4 update the register + refactor doc with the measured before/after numbers and any probe deltas.

### After the refactor
The rest of W0 (security G5/G21/stream-cap/witness-scanner, the JS throw-chain, the other correctness bugs)
and W3+ (dead code, splits, colour, CSS/distinctiveness, a11y, perf, the full verify.sh rewrite) follow, per
the crosswalk in [audit-2026-07-10.md](audit-2026-07-10.md).

## 11. R1 PROBE RESULTS (2026-07-10) + RE-PLAN

Three disposable probe members ran in parallel (isolated worktrees, reverted). All lead-verified against
source.

- PROBE C (left-dock key): CLEAN. `key="center"` on the `#center` div fixes the REPLACE app-side, no
  Transpile patch. Headless-proven (baseline: composer text lost + node replaced; fixed: text + node
  identity + focus preserved). Cosmetic: the SSR renderer emits a stray `key=` attr the client ignores.
- PROBE B (multi-component + State): MINOR + a hard constraint. Multiple top-level SIBLING client components
  hydrate + scope independently (measured: a store append re-rendered MessageLog ONLY, a panel toggle Shell
  ONLY); the publish-State-handle-to-door pattern works; no ziex change. CONSTRAINT: the components must be
  DOM-disjoint SIBLINGS under one root, NEVER nested (nesting collapses to lockstep: the inner marker is
  wiped, both redraw). So docks-flank-chat must be CSS layout across siblings, not DOM nesting. Blind spots:
  only 2 siblings tested; streaming render-cache across the split boundary NOT tested.
- PROBE A (memoization + tree-free): MAJOR on the tree-free; memoization sound with two fixes.
  - MEMOIZATION works, MEASURED N->1 per token (118->6 MessageView renders, sanitizes 29->5; real wasm, 200
    tokens over 4 msgs). Two REQUIRED fixes: (1) CARRIER: a persistent `VNode.memo` field (u64 hash VALUE,
    not a pointer - the component_fn key dangles post-resolution). (2) SIGNAL: content-sensitive (body ptr
    XOR len, or a hash), NOT the pointer alone - `store.zig:93` keeps `body.ptr` stable while a streaming
    tail grows, so a pointer-only signal FREEZES the streaming message (observed). Also memoize the keyed
    pass-2 reorder path, not just pass-1 (the append-only store hides pass-2 today).
  - TREE-FREE one-render grace does NOT hold, and no finite grace does. `registerVElement`
    (`Client.zig:205/:216/:422`) walks the whole root every render and dereferences every vnode's per-render
    `.component.element.attributes` (`x.zig:102`). A memo-skipped vnode's `.component` FREEZES at its
    last-resolved render, so the walker re-reads that frozen per-render allocation forever = read-after-free
    at ANY grace depth (native model asserts it at depth 1/2/3). AND: `Client.render` draws persistent
    (VNodes, registries) and transient (resolved elements) from ONE allocator, so per-render freeing needs
    arena separation first; "Component.deinit one render late" would not even free the leak (it misses the
    adopted resolved elements). Blind spot: r1a proved the grace FAILS with a native model, did NOT build +
    prove the arena+walker-skip FIX.

RE-PLAN (design-probe MAJOR -> re-approval per no-premature-starts):
1. DECOUPLE memoization from the tree-free. Ship memoization ALONE first: sound (with the carrier+signal
   fixes), delivers the measured N->1 win, and CUTS leak growth from O(N)/render to O(1)/render (skipped
   messages never re-resolve). Memoization WITHOUT freeing is SAFE - the existing leak keeps the frozen
   skipped pointers alive, so `registerVElement`'s re-deref reads leaked-but-valid memory.
2. DEFER the tree-free to its own effort (perf phase / a dedicated ziex arena re-architecture: per-render
   arenas + persistent-vs-transient separation in `Client.render` + whole-tree walkers skipping memoized
   subtrees). Bigger than proposed; probe it on its own. Not coupled to the perf win.
3. R4 region decomposition: siblings-only + CSS layout (Probe B constraint). This likely makes Probe C's
   `key` fix STRUCTURAL/moot (a sibling MessageLog is untouched by a Shell panel toggle), but keep the
   `key` as cheap defence if the final boundary still keeps `#center` under a shared parent.
4. The concatRawText leak fix (R2.2) still lands (independent). With memoization's O(1) leak growth, the
   remaining leak is far smaller pending the deferred tree-free.

REMAINING GAPS (flag before/during the real build, not blocking the re-plan):
- COMBINED behavior untested: memo + sibling regions + REAL streaming were each probed in ISOLATION. The
  combined interaction (render-cache + streaming across a split component boundary) is the biggest remaining
  unknown. Fold a combined-behavior test into the first real R3 build as a gate.
- The tree-free FIX (arena+walker-skip) is unproven (only the simple version's failure is proven). Deferred.
- pass-2 reorder memoization untested (append-only store; needed before shipping if message
  reorder/deletion ever lands).

## 10. Open design questions (RESOLVED by R1, see section 11)

- The memo signal shape: body-pointer alone, or (key + sealed-flag + pointer)? Streaming message must never
  skip; a message appended behind the streaming one must not alias.
- Door-drives-MessageLog wiring: State-handle-to-global (a) vs scheduleRenderByName (b). Prefer (a).
- Whether to also fix the empty-fragment collapse at Transpile.zig:1658 as part of this, or separately.
- Whether the concatRawText leak fix (toOwnedSlice) lands with the memo patch or as a standalone ziex fix
  first (it is independent and unblocks correct measurement).
