---
description: Fresh-eyes correctness / memory-safety / logic / a11y audit of the client's own Zig and .zx source, 2026-07-10. Scoped to what the 2026-07-10 backlog missed.
tags: [audit, client, wasm, zig, ziex, zx, a11y, memory-safety]
date: 2026-07-10
---

# Zig + .zx source audit (w05)

Tree: `client/` at repo HEAD `5be4f1638`. That commit touches only `public/scripts/accessibility-labels.js`,
so the client tree here is byte-identical to the brief's expected `bab3a3628`.

Scope: all 15 `app/pages/*.zig` + `app/main.zig` + all 10 `app/pages/*.zx`, read in full. Findings the
existing backlog (`notes/audit-2026-07-10.md`) already lists are NOT relisted, except where a claim there is
now wrong or where a new finding needs it for context. Two ziex internals (`vdom.zig` `reconcileChildren` /
`flattenComponents`, `Transpile.zig` `transpileIf`) and one ziex export (`Client.zig:500 __zx_alloc`) were
read as evidence for app-source findings; they are not themselves audited here.

Severity: `BUG` wrong / breaks behaviour. `DRIFT` doc or comment contradicts the code. `NIT` cosmetic or
latent. `QUESTION` needs a judgment call.

## chat.zx

- [BUG] chat.zx:11 - the left-dock slot `{if (ui.openOn(.left)) |p| (<SidePanel/>)}` sits BEFORE `<div id="center">` and neither child carries a `key`. An else-less `{if}` transpiles to `else _zx.ele(.fragment, .{})` (`.ziex/src/core/Transpile.zig:1657`), and `flattenComponents` drops an empty fragment entirely (`.ziex/src/runtime/core/vdom.zig:415 countFlattened`), so `#content`'s child list is `[#center]` when the dock is closed and `[aside, #center]` when it is open. `reconcileChildren` pass 1 stops only on a KEY mismatch, not a type mismatch (`vdom.zig:484-502`): both children are keyless, so `old[0]=#center` is matched against `new[0]=aside`, `areComponentsSameType(div, aside)` is false, and a `REPLACE` patch destroys `#center`. Opening or closing the AI-config dock (the only left dock) therefore tears down `#center`, which contains `<main id="chat">` and `<footer id="composer">`: the composer's typed text, its caret, its focus, and the chat scroll position are all lost, and every message DOM node is rebuilt. The right dock is appended after `#center` and is unaffected, which is why this reads as an intermittent bug rather than a total one.
- [BUG] chat.zx:15 - `<main id="chat">` is nested inside `page.zx:3`'s `<main id="chat-root">`. Two `<main>` elements is invalid HTML and gives assistive tech two "main" landmarks, one inside the other, so landmark navigation lands in the wrong place.
- [BUG] chat.zx:15 - the message log carries no `role="log"` and no `aria-live="polite"`. Streamed assistant tokens mutate `mes_text` with no live-region announcement, so a screen-reader user never hears the reply arrive. This is the primary output surface of a chat client.
- [NIT] chat.zx:8 - `class={ui.motionClass()}` emits `class=""` for the default `system` motion pref. Harmless, but every render writes an empty class attribute.

## page.zx

- [BUG] page.zx:3 - `<main id="chat-root">` is the SSR mount point, so the whole app tree renders inside `<main>`. Per HTML-AAM, `<header>` maps to the `banner` role and `<footer>` to `contentinfo` ONLY when they are not descendants of `article`, `aside`, `main`, `nav` or `section`. Because `topbar.zx:5`'s `<header id="topbar">` and `composer.zx:4`'s `<footer id="composer">` both sit under this `<main>`, the app exposes zero `banner` and zero `contentinfo` landmarks. Changing the mount element to a `<div>` restores both and also fixes the nested-`main` finding above.

## layout.zx

- [BUG] layout.zx:14 - no skip link. The first focusable element is `topbar.zx:9`'s first drawer button, so a keyboard user tabs through all nine drawer buttons (and the panel close button, when one is open) before reaching the composer textarea, on every load and after every drawer toggle. The composer is the one control the page exists for.

## topdrawer.zx

- [BUG] topdrawer.zx:11 - the drawer overlays `#content` (topdrawer.zx:1, and `.top-drawer` in app.css) but nothing makes the obscured content unreachable: no `inert` on `#content`, no `aria-hidden`, no focus trap. Tab order and screen-reader reading order both walk straight from the drawer into the chat log sitting visually behind it. This is a DIFFERENT gap from the backlog's `topdrawer.zx:11 [DEFER]` item, which covers Esc-to-close and focus-return only; a drawer can gain both and still leak the background.
- [NIT] topdrawer.zx:11 - the panel title is announced twice: once as the `<section>`'s `aria-label` (which gives it `role="region"`), and again as the `<span class="panel-title">` text `PanelHead` renders inside it at panelchrome.zx:10.

## settings.zx

- [NIT] settings.zx:15 - `<p class="setting-note">` explains what the `system` option does, but nothing associates it with the control: no `aria-describedby` from the `role="group"` (or from the radiogroup the backlog's settings.zx:9 item converts it into). A screen-reader user operating the segmented control never hears the note.
- [NIT] settings.zx:8 - `<span class="setting-label">Motion</span>` is a visual label that is not programmatically the group's label; the group carries a duplicate `aria-label="Motion"` at settings.zx:9 instead. One `<label>`-equivalent association would replace both.

## message.zx

- [NIT] message.zx:15 - the streaming message's `mes_text` is rewritten on every token with no `aria-busy="true"` for the duration. Paired with the missing live region on the log (`chat.zx:15`), a screen reader that did announce the node would announce it once per token rather than once on settle.
- [NIT] message.zx:10 - `renderMessage` is called with the per-render `allocator`, but the sanitized bytes it returns are allocated from `std.heap.wasm_allocator` inside `sanitized.zig:46`. The parameter is used only for the quote-wrap and md4c scratch. The two lifetimes are correct today but the signature does not say so; a caller reading only `message.zx` would assume the result dies with the render arena.

## composer.zx

- [BUG] composer.zx:6 - `<textarea id="send_textarea">` has no `name` attribute and no associated `<label>` (only `aria-label`). HEAD commit `5be4f1638` establishes the project rule "guarantee id, name and label for every form control" and applies it to `public/` only, so this client diverges from the rule the same session set. A form control with no `name` also cannot participate in a native form submission if the composer is ever wrapped in one.
- [NIT] composer.zx:6 - `rows="1"` with no autogrow handler anywhere in the Zig, the `.zx`, or `glue/main.js`, so a multi-line message scrolls a one-row box.
- [NIT] composer.zx:5 - the three composer buttons each carry `title` and `aria-label` with identical text, same duplicate-announcement issue as topbar.zx:9.

## sidepanel.zx

- [BUG] sidepanel.zx:15 - `<div class="panel-resize" aria-hidden="true">` is the only way to change a dock's width, and it is pointer-only: no `role="separator"`, no `tabindex`, no `aria-valuenow`, no arrow-key handler in `ui.zig` or the glue. `aria-hidden` additionally removes it from the accessibility tree, so panel width is unreachable by keyboard and unannounced. `ui_state.setWidth` already exists and is exported as `__st_set_panel_width`, so the model side is done; only the control is missing.

## topbar.zx

- [NIT] topbar.zx:9 - each drawer button carries both `title={p.title}` and `aria-label={p.title}` with identical text. Several screen readers announce the accessible name and then the description, so the panel title is read twice per button.

## html.zig

- [BUG] html.zig:95 - `Cache.put` refuses to store any entry whose HTML is zero-length, on the stated grounds that it must be a failed sanitize. But `adopt` returns `""` for BOTH a failed dupe AND a door result of length zero, and DOMPurify legitimately returns `""` for a body that is entirely stripped (a message whose whole text is `<script>alert(1)</script>`, for example). Such a message is therefore never cached, so every single render re-runs `quotes.wrap`, md4c, and a full DOMPurify pass over it, forever. The two outcomes need distinguishing (a sentinel address, or an `?SanitizedHtml` from `adopt`), not conflating.
- [BUG] html.zig:107 - `key(body)` is `Wyhash.hash(0, body)` over the WHOLE body, and `cacheGet` calls it on every message on every render. A cache HIT therefore still costs O(body length), and `Cache.get` then does a full `std.mem.eql` against the retained source on top. The render cache does not remove the "O(total chat bytes) per render" cost that the backlog's Phase 1 memoization plan is built to remove; it only removes the md4c and DOMPurify passes. Any before/after measurement of that plan that reads this cache as free will be wrong.
- [BUG] html.zig:49 - `adopt` unpacks the door's `(ptr << 32) | len` word and is the single point where an untrusted 64-bit value from JS becomes a Zig slice, and it has NO test at all. `sanitize` is an `extern`, so no unit test can drive it, and the only test of the sanitize path (`html.zig:230`) exercises the non-wasm branch that returns the placeholder before `adopt` is ever reached. The bit-packing contract, the `addr == 0` empty case, and the door-buffer free are all unproven. Splitting the pure `(u64) -> ?[]u8` decode out of `adopt` would make all three testable natively.
- [NIT] html.zig:52 - on wasm32 `usize` is 32 bits, so `@intCast(packed_result >> 32)` panics in a safe build and is undefined in `ReleaseFast` if the door ever returns a high word above 2^32. The door cannot produce one today (linear memory is capped below 4 GiB) but nothing in this function enforces that.
- [NIT] html.zig:87 - on a genuine 64-bit Wyhash collision between two distinct live bodies, `get` returns null for whichever body does not currently own the slot and `put` then displaces the other. The two messages thrash: each render re-sanitizes both and retires the other's bytes into the ring. Correct (no UAF, the ring covers it) but the cost is unbounded and silent. Worth one line of comment at minimum.
- [NIT] html.zig:55 - `adopt` dupes the door buffer and then frees it, so every sanitize costs one extra full copy of the rendered HTML. Because both allocations come from `std.heap.wasm_allocator` (verified: `__zx_alloc` is `wasm_allocator.alloc(u8, size)`, `.ziex/src/runtime/client/Client.zig:500`), the door buffer could be adopted directly instead of copied.

Memory-safety verdict for this file: the `RetireRing` two-generation discipline, the `Cache` collision-retire path, and the failed-insert retire path are all correct, and the alignment and allocator provenance across the door check out (`__zx_alloc` and `__zx_free` both use `std.heap.wasm_allocator` with alignment 1, matching every `free` in `html.zig`, `bridge.zig` and `store.zig`). No UAF, double-free, or leak-on-error found.

## stream.zig

- [BUG] stream.zig:68 - the doc comment says "A `[DONE]` anywhere in the fed bytes seals the stream here ... Bytes after it are ignored". They are not. `drain` (stream.zig:122) keeps iterating complete lines after `emit` sets `saw_done`, and `store.appendTail` still has a live `stream_index` for all of them, so every `data:` token line that follows `[DONE]` IN THE SAME `feed` CALL is appended to the message body and counted in `self.tokens`. This is not exotic: `glue/main.js:226` merges every chunk that arrived in one animation frame into a single buffer before calling `__st_stream_append`, so a backend that writes `[DONE]` and anything else within the same ~16 ms window delivers both in one `feed`. `end()` (stream.zig:104-111) has the same shape. Either stop the drain loop when `saw_done` is set, or drop the claim.
- [BUG] stream.zig:36 - `Stream.line` has no size cap. A backend that streams bytes without ever sending `\n` (a hung proxy, a non-SSE error body served with `text/event-stream`, a hostile peer) grows `line` without bound until the wasm heap is exhausted. This is the untrusted-network boundary and `coding-style.md` INPUT VALIDATION requires a bound here. `store.tail` is bounded by the message the user asked for; `line` is bounded by nothing.
- [NIT] stream.zig:137 - `emit` treats each `data:` line as its own event. The SSE specification concatenates consecutive `data:` fields of one event with `\n` and dispatches on the blank line. No current backend of interest sends multi-line data, but the divergence is undocumented and would silently drop the newlines if one did.
- [QUESTION] stream.zig:153 - `tokens` is incremented for post-`[DONE]` lines (see the first finding). `bridge.streamDone`/`streamTokens` feed `verify.sh` assertions, so the counter is a test oracle. Should it count only lines emitted before the sentinel?

## completion.zig

- [BUG] completion.zig:21 - `parsePayload` is the JSON parser sitting directly on the untrusted SSE byte stream, and it has neither a `checkAllAllocationFailures` test nor a property/fuzz test. Every sibling on the same path has both (`utf8.zig:318`, `quotes.zig:454` and `:477`, `stream.zig:408`, `markdown.zig:121`, `store.zig:409`). `testing.md` REQUIRED TESTS names "parser / decoder / FFI / untrusted input" as needing a fuzz target plus committed corpus. Its OOM-propagation contract (the `error.OutOfMemory` re-raise at completion.zig:30, which `stream.zig` depends on to retry a line rather than drop a token) is asserted nowhere.
- [NIT] completion.zig:29 - `std.json.parseFromSlice` is called with default options on a payload of unbounded length, so a single very long `data:` line allocates a full `std.json.Value` tree. Pairs with the `stream.zig:36` unbounded-line finding; a cap on one bounds the other.

## quotes.zig

- [BUG] quotes.zig:199 - `rawTagEnd` calls `paragraphEnd(src, at)` for EVERY `<` byte, and `wrapInline` calls `paragraphEnd(src, j + n)` for every backtick run (quotes.zig:245). `paragraphEnd` (quotes.zig:117) scans forward to the next blank line or to the end of the source. A message body with no blank line therefore costs O(n) per `<` and per backtick run, so one `wrap` call over such a body is O(n^2) in itself. This is a DIFFERENT quadratic from the one the backlog records: the backlog's item is "re-wrap of the full body every stream frame", which multiplies on top of this one. Hoisting `paragraphEnd` to a per-line cache, or bounding it to the current line, removes it.
- [NIT] quotes.zig:260 - the quote-pair match runs `std.mem.indexOfPos` over the rest of the line for every candidate opening delimiter, so a line of n quote characters is O(n^2) inside a single line. Same class as above, smaller constant.
- [BUG] quotes.zig:477 - `wrap_only_ever_inserts_q_tags_into_random_bytes` asserts only that stripping `<q>` and `</q>` returns the source bytes. It does not assert the module's headline invariant, stated at quotes.zig:5: "A quote inside code is never wrapped." A regression that wrapped a quote inside a fenced block, an indented block, or a `<script>` body would still strip cleanly back to the source and the property test would pass. The alphabet already contains backticks, `~`, `<` and newline, so the corpus reaches those states; only the assertion is missing. Add: no `<q>` may appear at an offset the source considers code.

## markdown.zig

- [BUG] markdown.zig:125 - `toHtml_never_panics_on_random_bytes` has zero assertions and discards the returned HTML. `testing.md` STRONG ASSERT bans a discarded result with no follow-up assert; the SMOKE EXCEPTION does not apply because the name is not one of the sanctioned suffixes AND the SUT has an observable return value. Two cheap strong asserts are available and would have caught real regressions: the output is valid UTF-8, and `MD_FLAG_NOHTML` being unset means every input byte outside a markdown construct survives.
- [DRIFT] markdown.zig:125 - the name says "random bytes"; the body draws from a 21-character ASCII alphabet. No non-ASCII, no NUL, no byte above 0x7f ever reaches md4c through this test, even though the streaming path routinely feeds it UTF-8.
- [NIT] markdown.zig:66 - on an md4c parse failure `toHtml` returns a copy of the raw markdown source. That is then handed to `sanitizeHtml`, so it is safe, but it silently renders markdown syntax as literal text with no signal to the user or the console. On wasm this is also the OOM path, because `libc_shim.alloc` returns null and md4c reports `-1` rather than propagating: an out-of-memory md4c parse is indistinguishable here from a malformed document.

## libc_shim.zig

- [NIT] libc_shim.zig:18 - `alloc` computes `header + size` with no overflow check. In `ReleaseFast`/`ReleaseSmall` a `size` within `@sizeOf(usize)` of `maxInt(usize)` wraps to a tiny allocation, and the very next line writes a `usize` into it. Unreachable through md4c on wasm32 today (linear memory caps the input well below 4 GiB), but this is `malloc` and it is one `std.math.add` away from being unconditionally safe.
- [NIT] libc_shim.zig:68 - `formatInto` is never tested with `size == 0`, which is a legal C `snprintf` call. The code is correct for it (both write sites are guarded) but the guard is load-bearing and unpinned.

Memory-safety verdict for this file: `alloc`/`release`/`resize` round-trip the size header correctly, the `qsort` inner loop cannot underflow (`j >= gap` guards the `j -= gap`), `bsearch` cannot overflow its midpoint, `compareN` uses the unsigned-char comparison C requires, and `findChar` returns the terminator for `c == 0` as C requires. `put.one`'s `n + 1 < cap` reserves exactly one byte for the NUL. No defects.

## bridge.zig

- [BUG] bridge.zig:32 - `appendMessage` swallows an allocation failure completely: it frees the two door buffers, returns, and skips the `zx.client.rerender()`. The user sent or received a message and it silently does not exist, with nothing in the console and nothing on screen. `coding-style.md` ERROR HANDLING forbids a silent swallow. Same shape at bridge.zig:42 (`streamBegin` drops a refused or OOM stream begin, and `glue/main.js:274` then sets `begun = true` regardless, so the glue's `finally` calls `__st_stream_end` into a stream that never started and the caret spins with no message).
- [NIT] bridge.zig:57 - `live.feed(buf) catch live.end()` seals the message on OOM, which is the documented and correct choice, but the truncation is invisible: no console line, no marker in the body, no signal to the glue. `streamTokens` is the only evidence and nothing reads it on this path.

## ui.zig

- [NIT] ui.zig:78 - `onDrawer` reads `event.target`, not `event.currentTarget`. It works today only because `topbar.zx:9` renders `<button></button>` with no element children (the icon is a CSS `::before` mask, and pseudo-elements dispatch with the originating element as target). The first child element added to a drawer button, an `<svg>` or a `<span>` badge, silently breaks every drawer: `target.id` is empty, `panelIdFromDomId` returns null, the click does nothing.
- [NIT] ui.zig:88 - the three `export fn` here are unconditional, while `bridge.zig:77` gates its `@export` block on `if (is_wasm)`. Two conventions for the same job in the same layer.

## sanitized.zig

- [BUG] sanitized.zig:52 - `beginSse` and the `extern "env" fn sse_start` it wraps are dead. Nothing in the Zig tree, the `.zx` tree, `glue/main.js` or `verify.sh` calls `beginSse`; the glue starts streams from JS through `window.stStartStream`. The `extern` declaration nonetheless forces the door to keep supplying an `env.sse_start` import (`glue/main.js:190`) or the module fails to instantiate. Dead code that pins a live import contract is worse than plain dead code.

## unit_test.zig

- [BUG] unit_test.zig:389 - `no_zx_source_unwraps_sanitized_html_outside_the_sink` and `no_zx_source_forges_the_sanitized_witness` scan `.zx` files ONLY. `html.zig`'s own doc comment names the attack they exist to stop: "`.witness_token = undefined` compiles, and Zig has no field privacy." A `.zig` file in `app/pages/` can write `html.SanitizedHtml{ .bytes = raw, .witness_token = undefined }` and reach `@escaping={.none}` through `html.sink`, and no test in the tree sees it. `loadZxSources` already enumerates the directory; extending it to `*.zig` (excluding `html.zig` itself) and asserting zero `witness_token` occurrences closes the hole the module's own header admits to.
- [QUESTION] unit_test.zig:93 - `matchRawAttr` matches only the literal token sequence `@escaping = { .none }`. An `@escaping={mode}` written against a comptime constant, or any future spelling of the same attribute, is invisible to the scan: `scan.count` stays 0 for that element, its children are never checked, and the `total == 1` assertion at unit_test.zig:325 still passes because `message.zx` supplies the 1. Does the ziex parser accept a non-literal `@escaping` value? If it does, `total == 1` is not the guard it reads as.
- [NIT] unit_test.zig:193 - `childrenEnd` increments `depth` for a self-closing `<name/>` nested inside a raw element, so it can never find the matching close and returns null. That path sets an `offender` and fails the test, which is the safe direction, but the failure message would blame the wrong construct.

## fixtures.zig

- [NIT] fixtures.zig:42 - `sections[0].messages[3]` (the "Quote styles" message) is unreachable in production: `chat.zx:46` slices `messages[0..3]`. Together with the backlog's `sections[1..]` item, three of the four roleplay fixtures and both other sections ship in the wasm binary unused.

## Cross-cutting

- [BUG] app/pages/*.zx - the document contains no heading element at all. `grep -E "<h[1-6]" app/pages/*.zx` returns nothing across all ten templates. The three places that are visually headings are not marked as such: `topbar.zx:6` renders the brand as `<div class="brand">`, `panelchrome.zx:10` renders every panel's title as `<span class="panel-title">`, and `settings.zx:8` renders the setting label as `<span class="setting-label">`. Heading navigation is the primary way screen-reader users move through a page, and here it yields zero results, so there is no way to jump to the open panel or to identify the app. The same grep shows zero `tabindex`, zero `<label>` and zero `inert` in the template tree, which is the root of the resize-handle, form-control and drawer-overlay findings above.
- [BUG] app/pages - four modules define the same page-lifetime allocator selection independently: `store.zig:132 page_gpa`, `html.zig:150 static_gpa`, `libc_shim.zig:13 backing`, and `sanitized.zig:46`'s literal `std.heap.wasm_allocator`. Three of the four must agree exactly or the door's buffers are freed with the wrong allocator; nothing in the tree asserts that they do. The backlog records this as a style nit ("page-allocator selection duplicated 4x"). It is load-bearing for memory safety, not style: `libc_shim.zig:13` deliberately differs on the native target (`c_allocator`, not `page_allocator`), which proves the four are not mechanically interchangeable.
- [DRIFT] notes/audit-2026-07-10.md:26 - the `MD_FLAG_LATEXMATHSPANS` item is already fixed (`markdown.zig:25` no longer sets it, and markdown.zig:23 documents why). Likewise the `stream.zig:141 [DONE]` item is fixed. Both still read as open in the backlog's "Real bugs (do first)" list.
