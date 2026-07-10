---
description: Read-only audit of ziex (@ 26f594531d, materialized at client/.ziex) scoped to the subsystems the WASM client actually reaches. Findings not already covered by the four known defects.
tags: [audit, ziex, wasm, zig, vdom, memory-leak, uaf, transpiler, client]
date: 2026-07-10
---

# ziex audit (w05), 2026-07-10

Scope: ziex @ `26f594531d` as materialized at `client/.ziex`, with patches 01/02/04 applied to source
(`setup-ziex.sh:32`) and patch 03 applied to the compiled door (`patch-door.sh`). Audited only the
subsystems this app reaches. Repo HEAD at audit time `5be4f1638` (briefed `bab3a3628`; the one-commit
delta touches `public/scripts/accessibility-labels.js` only, nothing under `client/`).

Method: source read. Reachability confirmed against the wasm import table of `dist/assets/_/main.wasm`
(22 imports, dumped directly). No build, no run, no measurement.

Known defects D1-D4 (string cache, vdom text-pointer UAF, findCommentMarker handle leak, CommentMarker
handle leak) are NOT re-reported; status confirmed in the last section.

## reachability map

REACHED at runtime (browser, wasm):

- `runtime/client/Client.zig` - `renderAll`, `render`, event dispatch, `__zx_alloc`/`__zx_free`.
- `runtime/client/render.zig` - `applyPatches`, `createPlatformNodes`.
- `runtime/client/reactivity.zig` - `rerender()` ONLY. `State`, `scheduleRender`, `collectStateBoundEntries` unused.
- `runtime/client/window/document.zig` - `Document.init`, `findCommentMarker`, `CommentMarker`.
- `runtime/client/window.zig` - `Console`, `is_wasm`.
- `runtime/client/Event.zig` - reached via `onclick={ui.onDrawer}` (`topbar.zx:9`) and `ui.onClose` (`panelchrome.zx:11`).
- `runtime/core/vdom.zig` - `createFromComponent`, `diff`, `reconcileChildren`, `resolveComponent`, `flattenComponents`, `concatRawText`.
- `Component.zig` - `ComponentFn.init`/`call`/`setIdentity`.
- `x.zig` - `Context.ele`/`attr`/`attrs`/`expr`/`txt`/`cmp`/`fmt`.
- `App.zig` + `runtime/core/App.zig` + `runtime/core/App/Client.zig` - startup.
- `vendor/jsz` - `Object`, `value` (imports `valueGet`, `funcApply`, `valueDeinit`, `valueStringLen`, `valueStringCopy`).

REACHED at build time only:

- `core/Transpile.zig` - emits `app/pages/*.zx` -> `.zig-cache/zx_transpile/pages/*.zig`.
- `runtime/server/render.zig` - `zig build export` produced `dist/index.html` incl. the `<!--$c74cce9-->` markers.

NOT REACHED (unused-surface risk, not deep-audited). Absence of the extern in the wasm import table is
the evidence:

- `runtime/client/fetch.zig` - no `_fetchAsync` import. App streams via glue `fetch` + `__st_stream_append`.
- `runtime/client/websocket.zig` - no `_wsConnect` import.
- window timers - no `_setTimeout` / `_setInterval` import.
- routing - no `_getLocationHref` import; `runtime/core/Router.zig`, `routing.zig` unlinked.
- `runtime/core/Kv.zig`, `Cache.zig`, `Db.zig`, `Http*.zig` - `build.zig` declares no `features`, so
  `feat_kv_client` / `feat_kv_server` / `feat_cache_server` / `feat_sqlite_server` are all false
  (`build/init.zig:284`).
- `runtime/server/{Server,handler,pubsub,websocket,dispatch}.zig` - app is a static export, no server.
- `runtime/client/events/generated.zig` (109KB), `style/generated.zig` (1.1MB), `core/Render.zig`,
  `core/fmt/html/*`, `devtool.zig`, `lsp/*`, `cli/*`, `tui/*`.
- `_submitFormAction` / `_submitFormActionAsync` ARE linked (the `form` branch of `createPlatformNodes`
  drags them in) but the app has no `<form>` with an action handler, so they never fire.

## core/vdom.zig

- [BUG] .ziex/src/runtime/core/vdom.zig:381-391 - `concatRawText` returns `aw.written()` without
  `deinit()` or `toOwnedSlice()`. Per zig 0.16 `std/Io/Writer.zig:2686`, `written()` is a view into the
  Allocating's buffer, freed only by `deinit`/`toOwnedSlice`. So BOTH buffers built at :279 (`old_html`,
  dropped immediately) and :280 (`new_html`, handed to the RAW_HTML patch) leak. `Client.zig:405-416`
  frees only `UPDATE` patch data, never `RAW_HTML`. - app-exposed? yes - `message.zx:15` marks `mes_text`
  `@escaping={.none}`, one per message, and `bridge.zig:streamAppend` calls `zx.client.rerender()` on
  every streamed chunk. Each render leaks 2x the total sanitized HTML of every message on screen. This is
  the single largest per-render leak found, and it is not fixable app-side. Note for the fix: the
  allocated buffer is larger than `written().len` (capacity vs end), so `allocator.free(html)` on the
  patch slice is the wrong length; the fix must be `toOwnedSlice()` plus an explicit free of the patch.
  `render.zig:287-288` does `defer aw.deinit()` on the identical construct, which is the tell that the
  vdom site is an oversight.

- [BUG] .ziex/src/runtime/core/vdom.zig:53-94 - double free on OOM. `errdefer allocator.destroy(self)`
  is armed at :54 and stays armed for the whole fn. The `.component_fn` branch destroys `self` explicitly
  at :93, then `return try createFromComponent(...)` at :94. If that recursive call returns an error, the
  errdefer destroys `self` a second time. - app-exposed? no (OOM only) - latent, but `wasm_allocator`
  OOM is reachable given the leaks above, and a double free on the wasm heap corrupts silently (no page
  protection).

- [BUG] .ziex/src/runtime/core/vdom.zig:655-667 - `componentOwnerId` does up to two `std.fmt.allocPrint`
  calls (`"#{d}"` at :658, `"{s}/{s}:{s}"` at :659) per `.component_fn` per resolution, and the result is
  handed to `setIdentity` / stored as `owner_component_id`. Never freed. Called from :91, :368, :498,
  :526, :599, :602. - app-exposed? yes - one `MessageView` per message per render, so `2 * (3 + N)`
  allocPrints leaked per rendered frame, growing with conversation length.

- [BUG] .ziex/src/runtime/core/vdom.zig:393-413 - `flattenComponents` allocates a fresh `result` slice
  whenever any child is a fragment (:409) and never frees it. Called from `createFromComponent:79` and
  `reconcileChildren:477`. - app-exposed? yes - `chat.zx` `{for}` blocks transpile to fragments
  (`chat-inner` has 2), and a false `{if}` transpiles to an empty fragment (`#content`). Two leaked
  slices per render minimum.

- [BUG] .ziex/src/runtime/core/vdom.zig:415-430 - `countFlattened` drops empty fragments entirely
  (`count += 0; continue` at :421), so a false `{if}` does not hold its sibling slot. React keeps a null
  slot; ziex collapses it. Consequence in `reconcileChildren`: opening a LEFT dock changes `#content`'s
  flattened children from `[div#center]` to `[SidePanel, div#center]`; pass 1 (:484-506) compares old
  `div#center` against the new resolved `aside`, `areComponentsSameType` fails on the tag, and it emits
  REPLACE + a trailing PLACEMENT. - app-exposed? yes - `ui_state.zig:39-44` puts `ai_config`,
  `connections`, `formatting`, `world_info`, `settings`, `backgrounds` on `.side = .left`. Toggling any
  of them tears down and rebuilds the ENTIRE `#center` subtree (the whole chat log and the composer) in
  the DOM: scroll position lost, every message node recreated, every jsz handle for those nodes leaked
  (see render.zig finding). Right-side docks (`persona`, `characters`, `extensions`) append after
  `#center`, so they cost one cheap PLACEMENT. The asymmetry is the proof. Fix shape: emit `.none`
  instead of `.fragment` at `Transpile.zig:1658`, or keep an empty fragment as one `.none` slot.

- [NIT] .ziex/src/runtime/core/vdom.zig:369 - `comp_fn.setIdentity(component_id, @truncate(next_velement_id))`
  truncates a monotonically-growing u64 into the u16 `instance_id` (`Component.zig:35`). Collides after
  65536 vnodes. - app-exposed? no - `instance_id` only feeds `ComponentCtx._internal`, which this app
  never reads.

- [QUESTION] .ziex/src/runtime/core/vdom.zig:188-192 - `diff` short-circuits when old and new are both
  `.component_fn` with an equal `propsPtr`. But `createFromComponent:90-95` resolves every `.component_fn`
  and destroys the node, so a VNode's `component` is never `.component_fn`; the branch is unreachable. -
  app-exposed? no - flagging because the planned memoization work (patch #5, `audit-2026-07-10.md`) would
  land right here: the memo hook already exists and is dead. Worth deciding whether to revive it or to
  memoize in `reconcileChildren` as planned.

## runtime/client/Client.zig

- [BUG] .ziex/src/runtime/client/Client.zig:316 - `Document.init(allocator)` calls
  `real_js.global.get(Object, "document")` (`document.zig:167`), which the door services with `valueGet`
  -> `storeValue` -> a fresh `values[]` slot. `render()` never calls `document.deinit()`. One jsz handle
  leaked per render per component. - app-exposed? yes - every `rerender()`, so once per streamed token.
  Distinct from D3/D4, which fixed `findCommentMarker` and `CommentMarker`; this is the enclosing
  `Document` object and is still unpatched.

- [BUG] .ziex/src/runtime/client/Client.zig:331 - the per-render Component tree is never freed. `cmp.import`
  builds it via `x.zig` `Context.ele` (`x.zig:95` children copy, `x.zig:102` attributes copy) and
  `Component.zig:78` (`props_copy` per `_zx.cmp`) and `Component.zig:185` (`keyFromProps`). `Component.deinit`
  exists at `Component.zig:207` and has ZERO callers anywhere in the client path. The allocator is
  `zx.allocator` = `std.heap.wasm_allocator` (`App.zig:29`), not an arena. - app-exposed? yes - a whole
  fresh ChatView tree is allocated and abandoned on every render. COUPLING HAZARD: patch 01 makes the
  persistent vtree adopt the newest tree's pointers (`vdom.zig:281`, `:295`, `:318` re-point element
  children/attributes and text), so the leak currently masks a use-after-free. Freeing the tree at end of
  render would resurrect D2's crash for any pointer ziex retains; a correct fix needs a one-render grace
  (`diff` reads render N-1's `old_element.children` at `vdom.zig:279` before adopting render N). The app
  already honours exactly this grace for its own HTML via `sanitized.renderTick()` (`chat.zx:6`).

- [BUG] .ziex/src/runtime/client/Client.zig:252-262 - `unregisterVElement` removes the id from
  `id_to_velement` and clears the JS-side handler modes, but never removes the `(velement_id, event_type)`
  entries from `handler_registry` (:161). VElement ids come from a monotonic counter (`vdom.zig:14-18`)
  and are never reused, so the map grows without bound. - app-exposed? yes - every DELETION/REPLACE of a
  subtree containing an `onclick`. The panel-close button (`panelchrome.zx:11`) is destroyed on each panel
  close, and the left-dock REPLACE (see vdom.zig:415-430) destroys `#center` wholesale.

- [BUG] .ziex/src/runtime/client/Client.zig:272-279 - `dispatchEvent` wraps `event_ref` in a
  `zx.client.Event` and never releases the handle. The door mints it per event
  (`eventbridge` -> `storeValueGetRef(event)`), and `valueDeinit` is the only thing that frees a slot. -
  app-exposed? yes - one leaked jsz slot per drawer-button click (`topbar.zx:9`). (Separately, the app's
  own `ui.zig:77` leaks the `target` handle it gets from `ev.getEvent().ref.get(...)`; that one is app
  code, not ziex, but it doubles the per-click cost.)

- [BUG] .ziex/src/runtime/client/Client.zig:281-284 - `dispatchEventByName` calls
  `self.dispatchEvent(velement_id, event_type)` with 2 args; `dispatchEvent` (:272) takes 3 plus self
  (`event_ref` is missing). It compiles only because zig lazily analyzes unreferenced `pub fn`s, and there
  are zero callers in `.ziex/src`. - app-exposed? no - dead and broken. It fails to compile the instant
  anything references it.

- [BUG] .ziex/src/runtime/client/Client.zig:336-347 - `render` inserts the new vtree into `self.vtrees`
  BEFORE `createPlatformNodes` (:342) and `marker.replaceContent` (:343). If either fails, the map retains
  a vtree that was never mounted, and the NEXT render takes the diff path (:350) and emits patches against
  DOM nodes that do not exist. `renderAll:309` swallows the error (`catch {}`), so this is silent. -
  app-exposed? no (OOM only).

- [NIT] .ziex/src/runtime/client/Client.zig:305-306 - `renderAll` constructs a `Console` (a jsz handle)
  that is never used. - app-exposed? yes - it is deinit'd, so no leak, but it is two pointless door
  round-trips (create + destroy) per render, i.e. per streamed token.

- [NIT] .ziex/src/runtime/client/Client.zig:209,239 - `id_to_velement.put` and `handler_registry.put`
  swallow OOM with `catch {}`. A dropped entry silently disables that element's event handlers with no
  diagnostic. - app-exposed? no (OOM only).

- [NIT] .ziex/src/runtime/client/Client.zig:240-242,422 - `registerHandler` calls the door
  (`_setEventHandlerMode`) on every registration, and `render` re-registers the entire tree every render
  (:422). - app-exposed? yes - roughly 10 redundant door calls per render for this app's handler count,
  since the ids are stable across renders.

- [NIT] .ziex/src/runtime/client/Client.zig:328-332 - `current_render_id` (:328) and
  `core_vdom.current_component_owner` (:330) are set and never cleared, while `reactivity.active_component_id`
  (:329) is cleared at :332. - app-exposed? no - inconsistent lifetimes on three globals that mean the
  same thing; nothing reads them after the render for this app.

## runtime/client/render.zig

- [BUG] .ziex/src/runtime/client/render.zig:204-322 - `createPlatformNodes` discards the jsz handle for
  every DOM node it creates. `_ce`/`_ct` return a jsz ref (`window/extern.zig:4,8`; door
  `storeValueGetRef`), wrapped by `htmlElementFromRef`/`htmlTextFromRef` (:325-335). The child handles are
  dropped at :304 (`_ = try createPlatformNodes(...)`), and the returned root handle is dropped by every
  caller: :55 (PLACEMENT), :90 (REPLACE), and `Client.zig:342`/`:360` (which pass it to `replaceContent`
  and never deinit it). - app-exposed? yes - the first render creates the whole tree, and every appended
  message plus every left-dock toggle creates more. Each dropped handle both grows the door's `values[]`
  array AND pins the DOM node alive after `_rc`/`_rpc` detaches it, so removed nodes are never garbage
  collected.

- [BUG] .ziex/src/runtime/client/window/document.zig:287-304 - `clearContent` leaks a jsz handle per node
  it removes: `next_sibling` (:292) is never deinit'd, and the `removeChild` return value (:302) is
  discarded. `insertContent:283` likewise discards the `insertBefore` return. - app-exposed? yes - runs on
  hydration to clear the SSR subtree, and again on any root-type change.

- [NIT] .ziex/src/runtime/client/render.zig:63-66,98-107,118-131 - PLACEMENT, REPLACE and MOVE silently
  do nothing to the vtree when `getVElementById(parent_id)` misses: the DOM is mutated but the vtree is
  not, so the next diff runs against a stale tree. PLACEMENT additionally leaks the pre-created VNode in
  that case. No `else` branch, no diagnostic. - app-exposed? no - the parent is always registered on the
  paths this app takes.

- [NIT] .ziex/src/runtime/client/render.zig:188-190 - `formActionCallback` leaks `states_json` (the
  `Allocating` is never deinit'd) and `states_list`. `onFormActionResponse:162` leaks the parsed `states`. -
  app-exposed? no - `_submitFormAction*` are linked but the app has no form action handler.

## runtime/client/reactivity.zig

- [NIT] .ziex/src/runtime/client/reactivity.zig:133-135 - `getOrCreate` leaks `id_copy` if
  `state_store.put` fails. :197 `collectStateBoundEntries` swallows OOM per entry, silently returning a
  short list that then mis-indexes against the server's positional state array. :148 `applyJson` leaks the
  parsed value. - app-exposed? no - the app uses `rerender()` only, never `State`.

- [QUESTION] .ziex/src/runtime/client/reactivity.zig:31-38 - `component_subscriptions` is declared and
  never inserted into or read; `active_component_id` is written and never read. Unchanged at this HEAD,
  matching the wiki note. - app-exposed? no - confirm-only: is upstream expected to finish this, or
  should the fork delete it?

## runtime/server/render.zig (build-time)

- [BUG] .ziex/src/runtime/server/render.zig:79-80 - a `.text` node rendered under `escaping == .none` is
  passed through `zx.util.html.unescape`, which DECODES `&lt;` / `&gt;` / `&amp;` rather than writing the
  raw bytes verbatim. The client renderer writes the same content verbatim (`_srh` -> `innerHTML`), so
  server and client disagree on the bytes for the same tree. - app-exposed? no - `html.zig:22` makes the
  server emit `ST_SSR_PLACEHOLDER` for `mes_text`, which contains no entities (confirmed in
  `dist/index.html`). It bites the moment real message bodies are ever server-rendered, and it would
  decode exactly the entities DOMPurify escaped on purpose. The placeholder is what is shielding the app,
  not the code.

- [NIT] .ziex/src/runtime/server/render.zig:19-45 - `AsyncComponent.renderScript` deinits the first
  `Allocating` only on the error path (`errdefer` at :21); on success the `html` buffer leaks. Same for
  `script_writer` (:28) whose `written()` is returned. - app-exposed? no.

- [NIT] .ziex/src/runtime/server/render.zig:234-275 - the `if (attribute.value)` block sits outside the
  handler `else`, so an attribute carrying BOTH a handler and a value would emit `="..."` with no
  preceding name, producing malformed HTML. - app-exposed? no - `x.zig`'s `attr` never sets both today.

## x.zig / Component.zig

- [BUG] .ziex/src/x.zig:95,102,206 and .ziex/src/Component.zig:78,84 - allocation failure is handled with
  `@panic("OOM")`. On wasm that is a trap with no recovery path, and `renderAll` cannot catch it. -
  app-exposed? yes, eventually - the leaks above make `wasm_allocator` exhaustion a matter of session
  length, and the failure mode is a hard trap rather than a degraded render.

## core/Transpile.zig (constructs this app uses)

- [BUG] .ziex/src/core/Transpile.zig:1752,1904,1925 - `{for}` emits
  `_zx.getAlloc().alloc(zx.Component, N) catch unreachable`. See the generated
  `.zig-cache/zx_transpile/pages/chat.zig:56,67` and `topbar.zig:44`. `build.zig:11` defaults the app to
  `ReleaseSmall`, where `unreachable` is undefined behaviour rather than a trap. `N` is
  `store.slice().len`, which grows with the conversation. - app-exposed? yes, latent - an OOM inside a
  `{for}` is UB in the shipped build, not a clean panic.

- [BUG] .ziex/src/core/Transpile.zig:1752 - the slice `{for}` allocates is then COPIED by `Context.ele`
  (`x.zig:94-98`, `.children = __zx_children_0` -> `allocator.alloc` + `@memcpy`). Both the original and
  the copy leak. - app-exposed? yes - two extra leaked allocations per `{for}` per render, and `chat.zx`
  has two `{for}` blocks.

- [BUG] .ziex/src/core/Transpile.zig:1658 - `{if}` with no else emits `else _zx.ele(.fragment, .{})`,
  the empty fragment that `countFlattened` then erases. Root cause of the `#center` rebuild described
  under `vdom.zig:415-430`. - app-exposed? yes.

- [NIT] .ziex/src/core/Transpile.zig:42-53 - `generateComponentIdInner` = `"c" ++ md5(name ++ path ++ index)[0..3]`,
  per JSX site not per instance. - app-exposed? no - confirm-only, already documented; the app has one
  CSR site and `dist/index.html` carries `<!--$c74cce9-->` for it.

- Event handlers: `onclick={fn}` transpiles to `_zx.attr("onclick", fn)`, `diff` skips every `on*`
  attribute (`vdom.zig:222,248`), and `Client.render:422` re-registers the tree each render. No finding;
  the generated code for this construct is correct. `@escaping={.none}` and `@rendering={.client}` also
  generate correctly; their defects are in the runtime, listed above.

## App.zig

- [BUG] .ziex/src/App.zig:100-103 - `resolveOptions` declares `var kv_wasm = zx.Kv.Wasm{}` as a STACK
  LOCAL and stores its address into the global `zx.kv` vtable (`Kv/Wasm.zig:68-70` sets
  `.userdata = wasm`). The local dies on return, leaving `zx.kv` dangling. - app-exposed? no -
  `feat_kv_client` is false (`build.zig` declares no `features`; `build/init.zig:284`). Latent for any
  ziex app that turns the client KV feature on. `Client.zig:187-193` has the same call against a
  module-level var, which is the correct shape.

- [NIT] .ziex/src/App.zig:80-81 - `datadir` / `staticdir` are joined (two allocations) before the
  freestanding early-return at :105, and `cleanupOptions` is skipped for freestanding (:239). Two small
  strings leaked once at startup. - app-exposed? yes, trivially.

## door / patch tooling

- [DRIFT] client/dist/vendor/ziex/wasm/init.js:215-227 - still carries the UNPATCHED cached `readString`
  (D1). `patch-door.sh` only rewrites `dist/vendor/ziex/wasm/index.js` (its default argument), which is
  the file the glue actually loads (`glue/main.js:6` `ZIEX_DOOR`), and `prune-dist.sh` deletes `init.js`
  because it is not in `KEEP`. So the shipped bundle is clean. But `build.sh` does not invoke
  `prune-dist.sh`, so an unpruned `dist/` on disk holds a stale door with the D1 bug in it. -
  app-exposed? no - confirm-only. Worth a guard: `verify.sh:37` checks only `index.js`.

## status of the four known defects (confirm only, not re-reported)

- D1 readString cache: PATCHED in the loaded door. `dist/vendor/ziex/wasm/index.js:230-232` is the bare
  `textDecoder.decode` form. See the DRIFT item above for the stale `init.js` copy.
- D2 vdom text-pointer UAF: PATCHED. `vdom.zig:318` re-points unconditionally, outside the `if`.
- D3 findCommentMarker handle leak: PATCHED. `document.zig:331` `defer body.deinit()`, `:334`
  `defer walker.deinit()`, `:350-351` per-iteration `retained` flag.
- D4 CommentMarker handle leak: PATCHED. `document.zig:265` `CommentMarker.deinit`, `Client.zig:322`
  `defer marker.deinit()`.
- Re-render scoping limits: UNCHANGED. `reactivity.zig:204-208` `rerender()` -> `renderAll()` is still the
  only public reactive entry; `scheduleRender:214-227` still falls back to `renderAll` for unregistered
  ids; `x.zig:543-545` still inlines a nested `@rendering={.client}` component.

## index

Not yet added to `client/notes/README.md` (the file does not exist; `audit-2026-07-10.md` records the
same pending item). Companion doc: [audit-2026-07-10.md](./audit-2026-07-10.md).
