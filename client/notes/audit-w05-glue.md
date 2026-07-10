---
description: Line-by-line audit of the JavaScript glue (client/glue/main.js + vendor) at HEAD 5be4f1638. Findings the 2026-07-10 backlog missed. Read-only pass, no fixes applied.
tags: [audit, client, glue, javascript, wasm, dompurify, highlightjs, supply-chain]
date: 2026-07-10
---

# Glue audit: client/glue (w05)

Tree audited: HEAD `5be4f1638`. `git diff bab3a3628..HEAD -- client/glue/` is empty, so this surface is
byte-identical to the tree the brief named. Phase 0 of `audit-2026-07-10.md` is already applied
(commits `fcec85934`, `12597b70f`, `bab3a3628`); its fixed items are not relisted here.

Files covered: `glue/main.js` (471 lines, every line), `glue/vendor/purify.es.mjs`,
`glue/vendor/hljs.mjs`, `glue/vendor/vendor-hljs.py`, `glue/vendor/hljs-theme.css`. Those are the only
`.js`/`.mjs`/`.py` files under `glue/`. `glue/app.css` is another member's surface and is untouched here.

Counts: 6 BUG, 3 DRIFT, 16 NIT, 3 QUESTION.

## Cross-check: JS env imports vs Zig externs (clean)

Both `extern "env"` declarations have a JS implementation and both signatures line up. All nine wasm
exports the glue calls exist as unconditional `@export`/`export fn`. No name mismatch, no missing export,
no arity mismatch.

- `env.sanitize` (main.js:169) matches `html.zig:24 extern "env" fn sanitize(ptr, len) u64`. The `(ptr << 32) | len` packing at main.js:38 matches the unpack at `html.zig:50-52`.
- `env.sse_start` (main.js:190) matches `sanitized.zig:17 extern "env" fn sse_start(ptr, len) void`.
- `__zx_alloc` / `__zx_free` (main.js:26,42) resolve to `Client.zig:500,509`, both backed by `std.heap.wasm_allocator`, which is the allocator `html.zig:54` frees the returned buffer with. Consistent.
- `__st_append_message`, `__st_stream_begin`, `__st_stream_append`, `__st_stream_end`, `__st_stream_tokens`, `__st_stream_done` all exist at `bridge.zig:79-84`.
- `__st_set_panel_width`, `__st_close_panel`, `__st_set_motion` all exist at `ui.zig:88,93,99`.
- Buffer ownership is correct on the happy path: `bridge.zig:56 streamAppend` frees the door buffer, and `store.append` / `stream.begin` adopt on success and free on error, so the glue is right not to free after those three calls.

## glue/main.js

Every BUG below is new. G1, G2 and G3 are one causal chain rooted at a single unguarded call.

[BUG] G1 glue/main.js:187 - `return writeString(out)` sits OUTSIDE the try/catch that lines 172-186 install, and `writeString` -> `writeBytes` -> `writeRaw` throws `Error('__zx_alloc returned null')` (main.js:27) whenever the wasm heap cannot serve the sanitized HTML - the comment at :172-173 states "Never throw back into the wasm door", and this is the one path that does; a JS exception raised inside a wasm import unwinds the wasm frames without running a single Zig `defer`, so the door's cleanup, the render, and `html.zig`'s retire-ring bookkeeping are all abandoned mid-flight. Trigger is heap exhaustion or an oversized body, not everyday input, but the code claims the path does not exist.

[BUG] G2 glue/main.js:53-59 - double free plus use-after-free of the message name and body, reachable only via G1: `bridge.zig:32` runs `store.global.append(name, body)` (which ADOPTS both buffers) and only then calls `zx.client.rerender()` at `bridge.zig:37`, that render re-enters `env.sanitize`, and a G1 throw propagates back out of `wasm.__st_append_message` at main.js:53 - so `adopted = true` (:54) never executes and the `finally` at :55-59 frees `n` and `b` while `Store.messages` still holds them as `name_owned` / `body_owned`; the next render reads freed bytes and `Store.deinit` frees them a second time. The `adopted` flag correctly guards the pre-adoption throws but cannot see a throw raised after adoption.

[BUG] G3 glue/main.js:243 - the door buffer leaks when `env.sanitize` throws during the rerender that `__st_stream_append` drives: `bridge.zig:56` owns the free through `defer store.global.allocator.free(buf)`, and a G1 exception unwinds past that defer, so one buffer is stranded per occurrence while the `finally` at :244-246 lowers `streamRender` and the outer catch at :254 quietly ends the stream. The same unwind through `bridge.zig:46 streamBegin` leaves `store.stream_index` set and `live.state == .streaming` with no message ever completed.

[BUG] G4 glue/main.js:273-274 - `wasm.__st_stream_begin` returns `void` and `bridge.zig:42-45` swallows every `live.begin` failure (`error.StreamInProgress`, OOM) by freeing the name and returning, yet main.js sets `begun = true` on the very next line unconditionally, then fetches the URL and flushes every chunk into a stream whose state is not `.streaming`, where `stream.zig:70` discards them all - the user watches a real network request produce no message, no error, and `stats.tokens` reporting 0. This is the silent no-op path the brief asked for: the export needs a status return, and the glue needs to honour it.

[BUG] G5 glue/main.js:65-72 - `MESSAGE_CONFIG` leaves `ALLOW_DATA_ATTR` and `id` at DOMPurify's permissive defaults, so message content hijacks the glue's own delegated listeners: `ALLOW_DATA_ATTR` defaults true (`purify.es.mjs:598,764`, regex `:321` matches `data-motion-set`), `id` is in the 118-entry default attr allowlist, and `SANITIZE_DOM` (`purify.es.mjs:1624`) only drops `id`/`name` when the value collides with a document or form named property, which `send_textarea` does not - therefore a message body carrying `<button data-motion-set="off">` drives main.js:400-406 into `localStorage.setItem` plus `__st_set_motion`, a body carrying `id="send_textarea"` captures the auto-grow handler at main.js:410-415, and a body carrying `id="probe-metrics"` has its text overwritten by `JSON.stringify(stats)` at main.js:301-302 on every stream end in the production path. Classes are namespaced to `custom-` at :110, so class-keyed selectors (`.panel-resize`, `.top-drawer`, `.drawers > button`) are safe; ids and data attributes were never given the same treatment. Fix is `ALLOW_DATA_ATTR: false` plus `SANITIZE_NAMED_PROPS: true` (or `FORBID_ATTR: ['style','id','name']`) in `MESSAGE_CONFIG`.

[BUG] G6 glue/main.js:138 - `const growing = streamRender ? blocks.length - 1 : -1` treats a process-wide flag as if it were scoped to the streaming message, and the comment at :136-137 ("that rerender re-sanitizes the streaming body alone") is false: `sanitized.zig:24-26` re-enters `env.sanitize` for ANY message that misses the `html.zig` cache, and two real misses can land inside a stream frame - a body whose earlier sanitize failed is deliberately never cached (`html.zig:95`) and a Wyhash key collision displaces a live entry (`html.zig:102`) - so an innocent settled message re-rendered during a flush has its last `pre > code` block skipped by `i === growing` (:155), after which `html.zig:116 cachePut` stores that un-highlighted HTML for the life of the page because entries never expire (`html.zig:93`). The defect is persistent, not transient.

[DRIFT] G7 glue/main.js:191 - `startStream(readString(ptr, len), 'Seraphina')` hardcodes the speaker name in the glue, and `sanitized.zig:52 beginSse(url)` carries no name, so every SSE-started message is attributed to Seraphina no matter which character is active - the name is store state and the extern signature is the thing that needs to change, not the string.

[DRIFT] G8 glue/main.js:369 - `Math.max(240, Math.min(620, w))` duplicates bounds that `ui_state.zig:50-51` already owns as `min_width` / `max_width` and that `ui_state.zig:104 setWidth` clamps again on receipt, while `ui.zig:16-17` already re-exports both - editing the Zig constants leaves the drag silently clamped to the old range, and the two clamps can disagree with no test catching it.

[DRIFT] G9 glue/main.js:250,298,299,381,394,425 - three inconsistent policies for calling exports that are all mandatory: `__st_stream_done` is `&&`-guarded (:250), `__st_stream_end` and `__st_stream_tokens` are called bare (:298-299), and `__st_set_panel_width` / `__st_set_motion` / `__st_close_panel` are guarded (:381,:394,:425), yet all nine are unconditional `@export`s (`bridge.zig:79-84`, `ui.zig:88,93,99`) - the guards convert a missing export into a silent no-op, so dropping `__st_stream_done` would quietly undo the `[DONE]` termination that `12597b70f` just landed, and boot only ever asserts `__zx_alloc` (:348). Assert the whole export set once at boot, then call unguarded.

[NIT] G10 glue/main.js:138 - `blocks.length - 1` assumes the growing code block is the last one, which stops being true the moment the streamed body closes a fence and continues with prose; that settled block is then skipped on every frame and rendered unhighlighted until `__st_stream_end` re-sanitizes with the flag down.

[NIT] G11 glue/main.js:74 - `URL_ATTRS` lists two attributes DOMPurify never emits (`xlink:href` and `formaction` are both absent from the 118-entry default attr allowlist, verified against the vendored bytes) while omitting two it does emit (`srcset` and `poster`); the omission is benign today only because DOMPurify's own `IS_ALLOWED_URI` rejects `data:` on them, so the set no longer describes the surface it claims to cover.

[NIT] G12 glue/main.js:107-108 - the class allowlist preserves `fa-`, `note-` and `monospace`, none of which have a single matching rule in `app.css` or `hljs-theme.css` (`monospace` appears only as a font-family value at `app.css:44`); they are inherited from upstream SillyTavern and are dead here.

[NIT] G13 glue/main.js:109 - `v.startsWith('hljs')` lets a message body keep any of the 46 `.hljs-*` selectors defined in `hljs-theme.css`, so `<span class="hljs-deletion">` in message content picks up theme colours; hljs classes are added after the sanitize gate (:145 and hljs's own output) and never need to survive it, unlike `language-*` which md4c emits upstream of the gate. This contradicts the project invariant that only themes and the custom-CSS box may change styles.

[NIT] G14 glue/main.js:90-95 - the `afterSanitizeAttributes` hook stamps `target="_blank"` on every node with a `target` property, so a markdown in-page anchor (`<a href="#heading">`) opens a new tab; `rel` is overwritten with `noopener` alone, discarding `noreferrer` and any `rel` DOMPurify kept.

[NIT] G15 glue/main.js:320-321,341-342 - `WebAssembly.instantiateStreaming.bind(WebAssembly)` throws a TypeError in any environment lacking `instantiateStreaming`, and `boot().catch` (:468) turns that into one console line plus a blank page; the `finally` then restores the bound wrappers rather than the native functions, so `WebAssembly.instantiateStreaming` stays a wrapper for the life of the page.

[NIT] G16 glue/main.js:394 - `MOTION[name] != null` reaches `Object.prototype`, so `data-motion-set="toString"` yields a Function that passes the null check and coerces to 0 at the wasm boundary; :404 also persists any attacker-chosen string into `localStorage` before the lookup ever runs. Use a null-prototype object or `Object.hasOwn`.

[NIT] G17 glue/main.js:410-415 - the composer auto-grow writes `style.height = 'auto'` then reads `scrollHeight`, forcing a synchronous layout on every keystroke, to reimplement CSS `field-sizing: content`; the reuse ladder puts the native platform rung above custom code here, and the inline height is invisible to the ziex vdom, so any `style` patch on the textarea clobbers it.

[NIT] G18 glue/main.js:298 - `__st_stream_end` runs a second time after `[DONE]` already sealed the framer through the `__st_stream_done` check at :250; `stream.zig:95` early-returns so no state is corrupted, but `bridge.zig:63 streamEnd` calls `zx.client.rerender()` unconditionally, buying one wasted full-tree render per stream.

[NIT] G19 glue/main.js:308-312 - `Promise.all` over the door, purify and hljs means a failed hljs fetch (378 KB, served locally) takes down the whole application instead of degrading to unhighlighted code; hljs is presentation only and nothing before :157 needs it.

[NIT] G20 glue/main.js:272 - `n` is never freed if `__st_stream_begin` traps, while `appendMessage` (:47-61) builds an explicit free-on-throw path for exactly the same adopt-on-success contract; the two doors deserve one discipline.

[QUESTION] G21 glue/main.js:70-71 - `FORBID_TAGS` lists only `style`, so DOMPurify's 119-tag default allowlist leaves `form`, `input`, `button`, `select`, `textarea`, `label` and `option` renderable inside a message body, `isSafeUri` (:76-87) permits any http(s) `action`, and the hook at :90-95 then stamps `target="_blank"` on the form - a model-authored message can therefore draw a convincing credential prompt that posts off-origin. Whether that is a BUG or an ACCEPT depends on a call I cannot make from the code: if message bodies are treated as untrusted LLM output, `FORBID_TAGS` needs the form-control set; if the fork is deliberately keeping upstream SillyTavern's permissive HTML-in-messages behaviour, this is documented intent and should be written down as such.

[QUESTION] G22 glue/main.js:131-164 - `highlightBlocks` assigns DOMPurify's output string to `tpl.innerHTML` and returns `tpl.innerHTML`, which is the innerHTML round trip DOMPurify's own guidance warns can resurrect mutation XSS, since the second parse runs in template-contents rather than body context; the standing mitigations are real (`style` is forbidden, and 3.4.11 ships `SAFE_FOR_XML` plus the namespace-confusion checks at `purify.es.mjs:1464-1469`) and I found no working vector, but the safer shape is to sanitize once with `RETURN_DOM_FRAGMENT`, highlight that fragment, and serialize once.

[QUESTION] G23 glue/main.js:357-388 - the drag closure captures `panel` and `handle` element references at pointerdown, and every streamed token triggers a full `zx.client.rerender()`; if a ziex diff ever replaces those nodes instead of patching them in place, `onMove` writes width to a detached element and `releasePointerCapture` targets a dead node. `touch-action: none` is correctly set at `app.css:284` and the pointer capture is correctly paired, so this is the one remaining hole. Not verifiable without running the app.

## glue/vendor/purify.es.mjs

Provenance verified clean. The vendored file is byte-identical to the npm `dompurify@3.4.11` dist build
apart from a stripped `//# sourceMappingURL` line. `3.4.11` is the current `latest` on the registry.
Upstream sha256 `8a40d0a0f66c217879826a4e97bca5ef88f1b751fe813d27cf4195165aa3778f`, vendored
`12e5392da072cba233c96b93510f2d219f0618d91ca2a9622705ef1eda1b4c38`. No local modification. The
unusual JSDoc prose in the file is upstream's own.

[NIT] G24 glue/vendor/purify.es.mjs:1 - the file has no provenance record: no integrity hash, no lockfile entry, no vendoring script, and `dompurify` appears in no `package.json` in the tree, so the next refresh is a manual copy that nothing can check - hljs at least has `vendor-hljs.py` to regenerate against a declared dependency, and the security-critical dependency of the two is the one with no such path.

## glue/vendor/hljs.mjs and glue/vendor/vendor-hljs.py

Provenance verified clean. Re-running `vendor-hljs.py` against `node_modules/highlight.js` reproduces
`hljs.mjs` byte for byte: 39 modules, 37 languages, from highlight.js `11.11.1`, which is the current
npm `latest` and is declared at `../package.json:59` as `^11.11.1`. The generator wraps source bytes
verbatim, as its docstring claims.

[NIT] G25 glue/vendor/vendor-hljs.py:15-17 - the docstring quantifies only the option it rejected ("the full set costs 428,487 gzipped bytes against the application wasm's 20,410") and never states what the chosen bundle costs: 378,003 raw and 100,335 gzipped, still 4.9x the wasm it is there to decorate, so the note reads as though the size problem were solved rather than reduced.

[NIT] G26 glue/vendor/hljs.mjs:1 - 16,412 lines of vendored code with no Subresource Integrity attribute and no pinned upstream hash; the generator reads whatever version `npm` happened to resolve for the `^11.11.1` caret range, so the bundle's provenance is a floating range rather than a fixed artifact.

[NIT] G27 glue/vendor/vendor-hljs.py:60-68 - `__require` writes the module object into `__cache` before executing the module body, so a `require` cycle hands back a half-populated `exports` rather than failing; highlight.js has no cycles today, and a future grammar that introduces one would break quietly at runtime rather than loudly at bundle time.

[NIT] G28 glue/vendor/vendor-hljs.py:46-47 - `__resolve` returns bare specifiers unchanged, so a `require('fs')` that ever reaches the bundle dies at runtime with `__mods[id] is not a function`, whereas the Python-side `resolve` (:72-77) raises `SystemExit` on the same input; the two resolvers disagree on failure mode, and only one of them runs in front of a user.

## glue/vendor/hljs-theme.css

Clean. 117 lines, static colour declarations only. No `url()`, no `@import`, no `expression()`, no
`javascript:`. Its 46 `.hljs-*` selectors are reachable from message content, which is G13.

## Index

Add to `client/notes/README.md` when it exists. Companion to `audit-2026-07-10.md`; this doc covers
only the glue surface and only findings that backlog missed.
