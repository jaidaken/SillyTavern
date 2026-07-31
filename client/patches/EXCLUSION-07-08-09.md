---
description: Why ziex patches 07, 08 and 09 are unapplied in SillyTavern; git history shows an unwired commit, not a decision, and the safety hypothesis is refuted by the may_suspend gate.
tags: [ziex, patches, memory-safety, zig, wasm]
date: 2026-07-31
---

# 07, 08, 09: the exclusion is an OMISSION, not a decision

HEADLINE: git history settles the origin question outright. There was never a decision to exclude.
The three patch files were authored, verified and committed, and the one line that would have made
`setup-ziex.sh` apply them was never written. Every later restatement ("deliberately unwired",
"excluded on purpose") is downstream of that gap and cites no source, because there is no source.

The reviewer's UAF hypothesis is SEPARATELY REFUTED by the `may_suspend` gate. Both halves below.

Neighbours: [the superseded local patch copy](./README.md), [the client build notes](../README.md).
The shared series lives at `~/desk/projects/ziex-patched/` and its README carries the same question.

## 1. THE GIT EVIDENCE (decisive)

commit `6d91a78f4` (2026-07-11) `perf(client): patch ziex handle + allocation leaks (patches 07-09)`.

- diffstat = 3 files, ALL ADDS, all under `client/patches/`. 157 insertions.
- `git diff 6d91a78f4^ 6d91a78f4 -- client/setup-ziex.sh` = **0 lines**.
- apply loop at that commit AND at its parent, byte-identical:
  `for p in "$PATCHES"/01-*.patch "$PATCHES"/02-*.patch "$PATCHES"/04-*.patch "$PATCHES"/05-*.patch "$PATCHES"/06-*.patch`
- trailing echo at that commit still reads `+ 5 zig patches`. It was not bumped to 8.

so the commit that ADDED the three patches did not WIRE them. its own message says otherwise:

> Three patches over the pinned ziex, **applied by setup-ziex** on top of 01-06

that sentence describes a tree that was never committed. the message also records a real
verification run:

> Verified: all 9 patches apply clean, zig build test green, build.sh exit 0, and a poison-on-free
> UAF detector (0xAA, 60-token stream + panel toggle + drawer click) was clean for every shipped free.

read together: the author had all nine applied in the WORKING TREE, ran an oracle against that
state, got a clean result, committed the patch files, and lost the one-line `setup-ziex.sh` edit.

- searched every commit touching `client/setup-ziex.sh` (17 of them, `ffe1db8c2` through `204e55df2`).
  `07`, `08` and `09` appear in the apply list in NONE of them, at any point.
- searched every commit touching `client/patches/` (16). `6d91a78f4` is the only one that adds,
  renames, modifies or deletes 07, 08 or 09. **never applied, therefore never reverted.**
- the exclusion has no revert commit because there was no application to revert.

CONSEQUENCE: the thing being preserved as a decision is the absence of an edit. The verification
the operator would want before applying these was ALREADY RUN, on 2026-07-11, against all nine.

## 2. THE HYPOTHESIS IS REFUTED (patch 09 cannot fire in this app)

hypothesis under test: patch 09 frees the per-dispatch jsz event handle when
`!handler.may_suspend`, so a handler registered NON-SUSPENDING that reads the event after return
(or defers into rAF / timeout / promise) gets a UAF on a jsz slot.

the gate runs the other way. `src/runtime/core/EventHandler.zig` sets `may_suspend`:

| constructor | may_suspend | reached from |
|---|---|---|
| `wrap` | **true** | plain comptime fn attr, name != "action" |
| `runtime` / `runtimePtr` | **true** | `&fn` runtime fn-ptr attr (`x.zig:242,244`) |
| `client` | **true** | `ctx.bind(fn(*ClientEvent) void)` (`contexts.zig:116`) |
| `clientS` | **true** | `ctx.bind(fn(*ClientEvent.Stateful) void)` (`contexts.zig:117`) |
| `server` / `serverS` / `serverSS` / `init` | false (default) | `ctx.bind(fn(*ServerEvent...))` |
| `action` direct-typed struct | false (explicit, ln 142) | `action={fn(SomeStruct)}` |
| `actionStateful` / `actionS` | false (default) | server actions |

**every client-side path sets `may_suspend = true`.** `may_suspend == false` is reached ONLY by
server-event and server-action handlers, whose callbacks are `eventHandler` / `actionHandler`,
both of which consume the event synchronously (`event.value()`, `event.preventDefault()`) before
handing off to `fetchAsync`, and whose response callbacks (`onActionResponse`, `onEventResponse`)
never touch the event.

THIS APP HAS ZERO OF THOSE. `grep -rc 'server\.Event|ActionContext|ServerEvent' client/app` = 0
matches in 0 files. no `action={...}` handler attribute exists (every `*-action` hit in `.zx` is an
HTML `data-` attribute). no direct `EventHandler.*` construction in `client/app`.

so `!handler.may_suspend` is FALSE for every handler this app registers, and the free at the end of
`dispatchEvent` NEVER EXECUTES on a found handler. patch 09's event free is inert here.

it is not a total no-op: the `orelse` branch frees when NO handler is registered for that
(velement_id, event_type). that branch is safe by construction, nothing holds the ref.

### 2b. the deferral half cannot happen either (structural, not a spot check)

even if a handler were non-suspending, it could not carry the event into deferred work:

- `window.zig:143` `pub const TimeoutCallback = *const fn () void;` and both
  `setTimeout(callback, delay_ms)` and `requestAnimationFrame(callback)` take exactly that type.
  **zero parameters, no context pointer.** there is no channel to pass an event through.
- fetch continuations take `(tag: u64, status: u16, res: ?*Response)`. no event.
- `zx.client.Event` (`client/Event.zig`) is a value struct wrapping `_internal.event_ref: u64`.
  retention would require storing that struct somewhere with a lifetime past the handler.
  scan for module-level `var`/`const` typed `client.Event` in `client/app`: **none**.
  scan for the event param assigned into anything: **none** (all 36 hits are `_ = ev;` discards).

## 3. HANDLERS ENUMERATED: 241 of 241 sites, 164 of 164 distinct expressions

denominator, and how it was counted: the 24 members of `Client.zig:123 EventType` are the only
attribute names ziex binds as DOM handlers (`fromAttributeName` does `stringToEnum` on the name
minus `on`). matching `on<EventType>={...}` over `client/app/**/*.zx` yields **241 binding sites**
and **164 distinct handler expressions**. no handler attributes exist in `.zig` files
(`.attr("on...")` = 0 matches), so `.zx` is the whole surface.

M is therefore 241 sites / 164 expressions, and N equals M. The claim is NOT that each of the 164
bodies was read line by line. It is that all 164 route through the four `may_suspend = true`
constructors in the table above, which is a property of the CONSTRUCTOR, not of the body:

- 46 are `ctx.bind(...)` -> `client` or `clientS`, both true.
- 16 are `&fn` -> `runtime` / `runtimePtr`, both true.
- 4 are `props.on*` passthroughs, each supplied by a parent as `&fn` (`&onSaveInstructPreset`,
  `&presets.pickInstruct`, `&onInstructPresetName`, `&onRetryPresets`) -> `runtime*`, true.
- the remaining 98 are plain comptime fn attrs -> `wrap`, true.

param shapes across the set: 130 by value `ev: zx.client.Event`, 50 by pointer, 54
`*zx.client.Event.Stateful`. none by-pointer form escapes, since the pointer is to a stack copy
made by the wrapper (`runtimePtr`, `client`, `clientS` all do `var e = event; f(&e)`).

## 4. VERDICTS

**07 node-handle-leaks: SAFE TO APPLY.** frees the jsz handle `createPlatformNodes` returns at
PLACEMENT and REPLACE and per child, plus the `next_sibling` / `removeChild` handles in
`CommentMarker.clearContent`. every consumer reads IDs (`ext._ib`, `ext._ac`, `ext._rpc`), never the
freed handle; the DOM node itself lives in the JS `domNodes` registry keyed by vnode id, so the
returned ref is a second handle to an object with an independent owner. the `defer` inside the
`while` in `clearContent` fires per iteration including the `break` paths.

**08 standalone-alloc-leaks: SAFE TO APPLY IN THIS APP, with a named latent hazard.** the two
`flattenComponents` frees are guarded `ptr != input.ptr` so a borrowed slice is never touched, and
the reconcile reads Components out by value. the hazard is the THIRD hunk. `componentOwnerId`
allocates, `comp_fn.setIdentity(component_id, ...)` stores that slice **by reference** into
`ctx._internal.component_id` (`Component.zig:159`, no copy), and patch 08 frees it right after
`comp_fn.call()` while the ctx still points at it. readers are `contexts.zig:84` (`ctx.state`),
`:116/:117/:120/:124` (`ctx.bind`) and `:165` (`collectStateBoundEntries`), all of which run DURING
the call, so the pointer is live when read. it dangles only between calls, and `resolveComponent`
(`vdom.zig:409`) rewrites it via `setIdentity` before every subsequent call.
`setIdentity` has exactly ONE call site; `comp_fn.call()` has SIX. the other five are
`server/render.zig:126`, `:141`, `core/tree.zig:23`, `x.zig:553` and `devtool.zig:238`. of those,
`tree.zig:23` is reached only from `server/handler.zig` and `core/injections.zig` (both SSR), and
`x.zig:553` is unreachable on the client because `x.zig:543` returns early when
`zx.platform.role == .client`. so no client-side reader sees the dangling slice. this is
correct-by-accident rather than correct-by-construction, and it is worth a comment upstream.

**09 client-handle-registry-event-leaks: SAFE TO APPLY.** the `handler_registry` prune on
`unregisterVElement` is a straight leak fix (the map was keyed by (velement_id, event_type) and only
`id_to_velement` was being cleared). the event free is gated off entirely in this app per section 2.
cost worth naming: the prune is an `inline for` over all 24 `EventType` members per unregistered
element, run recursively over the subtree, so a large teardown does 24x the map removals. that is
throughput, not correctness.

## 5. OTHER EXCLUSION CANDIDATES, CHECKED AND RULED OUT

- **conflict with 12-24**: no. zomboid-manager's `setup-ziex.sh` applies 07, 08 and 09 TOGETHER with
  12 through 24 (23 patches). the one textual interaction is patch 15's `unregisterVElement` hunk,
  and the shared copy already carries two context lines instead of three precisely so it applies
  both with and without 09. documented in [the local copy README](./README.md).
- **applied then reverted**: no. see section 1; the only commit touching these three files is the
  add. no revert, no modify, no delete.
- **10 and 11**: different cause, and understood. they patch ziex's tailwind plugin, which this
  project stopped compiling at `b32581174` (drop tailwind, esbuild bundles the stylesheet). they
  were dropped from the apply list in that same commit, WITH the reason recorded inline. that is
  what a real decision looks like in this tree, and 07-09 has no equivalent.
- **notes for 12-24 referencing 07-09**: nothing substantive. the grep hits inside those patch files
  are line numbers and index hashes, not prose.

## 6. ZOMBOID-MANAGER EXPOSURE

**not exposed**, by the same argument, independently checked. its client has 34 handler binding
sites and **zero** `server.Event` / `ActionContext` / `ServerEvent` / direct `EventHandler.`
constructions. so every handler there is also `may_suspend = true` and patch 09's event free is
equally inert. no change is indicated there.

## 7. WHAT REMAINS UNKNOWN

- **which of the two omission stories is true.** the evidence proves the patches were never wired.
  it does not distinguish (a) the `setup-ziex.sh` edit was made locally, verified, then lost before
  staging, from (b) the author changed their mind at commit time and left the message stale. (a) fits
  the message better, since a deliberate drop would have been written down the way 10 and 11 were.
  this is INFERENCE, labelled as such.
- **the original author's intent is unrecoverable.** no wiki note, no session note, no branch, no
  stash referenced in-tree.
- **nothing here was built, run or tested.** every conclusion in this file rests on reading source
  and git history. the only oracle in evidence is the 2026-07-11 poison-on-free run recorded in
  `6d91a78f4`, which this file quotes but did not reproduce. applying the three patches should be
  gated on re-running a build plus that detector, not on this document.
- **section 3 proves a constructor property, not 164 audited bodies.** if a future handler is
  registered through a server or action path, the gate opens and the hypothesis becomes live again.
