---
description: the ziex + wasm SillyTavern client. build, export, and run it locally.
tags: [sillytavern, frontend, zig, wasm, ziex]
date: 2026-07-15
---

# client

The Zig/wasm frontend for this SillyTavern fork, built on [ziex](https://github.com/ziex-dev/ziex).
It is a full client: the app shell, the character and persona panels, the chat log with live SSE
streaming and markdown, the reading-width and panel-resize gestures, and the character/chat CRUD.
Zig owns all application state; JavaScript is only the adapters the browser forces (see The door).

See [notes/frontend-stack.md](../notes/frontend-stack.md) for the stack decisions this implements.

## Requirements

Zig `0.16.0` (pinned in `.zigversion`). Node is needed at build time: ziex's tailwind plugin and the
`esbuild` minify step both run under it. The two vendored browser libraries are committed under
`glue/vendor/` (copied from `../node_modules`), so the running site fetches no third-party CDN.

## Build

Run `./build.sh`, not bare `zig build`. ziex is used through a patch series, and only the wrapper
applies all of it:

```sh
./build.sh              # OPT=ReleaseSmall by default
OPT=ReleaseFast ./build.sh
```

`build.sh` runs `setup-ziex.sh` (materialises the patched ziex into `.ziex`), then `zig build check`
and `zig build test` as gates, then `zig build` and `zig build export`, then `patch-door.sh`,
`esbuild` minification of the browser-fetched assets, and `prune-dist.sh`. The finished static site
lands in `dist/`; `./verify.sh` is the browser gate that runs against it.

`ReleaseFast` produces a far larger wasm for no gain on a DOM-diffing chat UI. Keep `ReleaseSmall`.

Bare `zig build` still works for a quick compile check, but it skips the patch series, the door
patch, and minification, so its `dist/` is not what ships.

## Run

```sh
python3 devserve.py --port 8080
```

Serves `dist/` and reverse-proxies `/api/*` and `/csrf-token` to `http://127.0.0.1:8000`, so the
browser sees one origin and no CORS. Binds `127.0.0.1` only. Exits cleanly on SIGTERM.

Flags: `--port` (default 8080), `--dist` (default `dist`), `--backend` (default `http://127.0.0.1:8000`).

## The door

ziex injects `glue/custom.js` as `<script defer src=...>` with no `type="module"` (wired by
`client.jsglue_href = "/glue/custom.js"` in `build.zig`), so it is a **classic script** and cannot
use a top-level `import`. It dynamic-`import()`s ziex's ESM door, DOMPurify, and highlight.js, then
calls `init({ importObject: { env } })`. ziex merges the `env` namespace into its own import object,
so the door adds host functions without changing ziex's public API. ziex itself is still patched, but
for unrelated runtime fixes (see Build); the door is not one of those patches.

`env` exposes exactly three host functions to Zig:

- `sanitize(ptr, len)` runs `DOMPurify.sanitize()` with SillyTavern's message config, then
  highlight.js over the code blocks. Returns the result buffer packed as `(ptr << 32) | len`,
  allocated with the wasm module's own `__zx_alloc`, so **wasm owns it**.
- `st_log(level, scope_ptr, scope_len, msg_ptr, msg_len)` is the console sink for the Zig logger.
  Zig owns the level thresholds; the door only prints what already passed the filter.
- `sse_start(ptr, len)` opens the streaming reply for a URL and feeds tokens back into the store.

Everything else the browser forces stays in JavaScript because it cannot cross the wasm boundary:
multipart upload (`File`/`FormData`) for character import and avatar replace, the blob download for
export, the SSE reader loop, and the pointer-capture drag gestures. Each is a thin `window.__st_*`
helper called from Zig (`char_api.zig`), which owns the surrounding data flow. The old JavaScript
DOM-bridge shims (`st_elem_*`, `st_node_*`, and the handle map) are gone; where Zig still needs the
DOM directly (setting `aria-busy`, scrolling to the newest message) it reflects through `jsz`, not a
bespoke bridge.

## Styling

Every component wears Tailwind utility classes inline. There is one stylesheet, `glue/app-input.css`,
which holds the design tokens, the generated-state rules, and the message frame's own styling. ziex's
first-party tailwind plugin (patched, `patches/10-tailwind-oxide-scanner.patch`, because the stock
regex extractor dropped every paren-bearing utility) compiles it **inside `zig build`** into
`zig-out/static/glue/app.css`, and the export step copies it to `dist/`. No separate Tailwind CLI
runs.

### Sanitization is the security boundary

Message bodies are markdown, rendered to HTML at runtime, so no class of ours can reach inside them.
`@escaping={.none}` accepts only a `SanitizedHtml`, whose sole mint in the whole program is
`html.sanitizeHtml` (`app/pages/html.zig`); it crosses into `env.sanitize` and comes back downstream
of DOMPurify. `SanitizedHtml` carries a witness pointer to a file-private `opaque` type, so a caller
in another file cannot write the struct literal, and `html.sink()` is the only unwrap.

Zig has no field privacy, so this is not unforgeable: `.witness_token = undefined` compiles. The
property actually achieved is that raw bytes cannot reach `innerHTML` by accident or by any ordinary
construction, and any bypass has to name an obvious escape hatch that review can grep for. That is
worth having, but it is not a proof.

Beyond SillyTavern's current behaviour (class namespacing to `custom-<name>`, forced
`target="_blank" rel="noopener noreferrer"`), the door additionally rejects `javascript:` URIs and
every `data:` URI whose mediatype is not an image, including `image/svg+xml`.

## Layout

```
build.zig                 ziex.init wiring: jsglue_href, tailwind plugin, export step
build.zig.zon             ziex + its tailwind plugin, pinned as path deps (.ziex)
build.sh                  the real build: setup-ziex, gates, build, export, patch, minify, prune
setup-ziex.sh             materialise the patched ziex into .ziex
patch-door.sh             edit ziex's exported door in place, post-export
verify.sh                 the browser gate against dist/
devserve.py               static server + API reverse proxy
app/main.zig              ziex app entry
app/pages/page.zx         the one route
app/pages/shell.zx        the app shell (grid, top bar, side panels)
app/pages/messagelog.zx   the chat log; message list + the reading-width handle
app/pages/message.zx      MessageView, one plain element per message
app/pages/composer.zx     the input composer
app/pages/panels/         the drawers (characters, personas, AI config, formatting, ...)
app/pages/bridge.zig      the door entry points: the __st_* wasm exports
app/pages/store.zig       the chat log and the owner of every message's text lifetime
app/pages/char_api.zig    Zig-owned data layer: boot, character/persona loads, chat open, CRUD
app/pages/net.zig         the fetch wrapper
app/pages/html.zig        SanitizedHtml + the extern "env" host functions
app/pages/reading_prefs.zig  persisted reading-width and motion prefs
glue/custom.js            the door: classic script, dynamic import, env namespace, JS adapters
glue/app-input.css        the one stylesheet, compiled by the tailwind plugin inside zig build
glue/vendor/              purify.es.mjs, hljs.mjs, hljs-theme.css
```

## Vendored JavaScript

`glue/vendor/purify.es.mjs` is copied verbatim from `dompurify` 3.4.11.

`glue/vendor/hljs.mjs` is **generated**. highlight.js 11.11.1 ships no browser ESM build: its
`es/index.js` re-exports `../lib/index.js`, which is CommonJS, and a browser importing it fails with
`SyntaxError: ... does not provide an export named 'default'`. `glue/vendor/vendor-hljs.py` walks
`require()` from an entry module, wraps each module's bytes verbatim in a function, and emits one ESM
file with a small CommonJS shim.

The entry is `lib/common.js` (36 languages) plus `nix`, not `lib/index.js` (all 192): the smaller set
covers what a model realistically emits into a chat. `highlightAuto` still runs over the registered
set; only its size changes. **highlight.js ships no Zig grammar**, so Zig code blocks fall back to
plaintext.

Regenerate after a highlight.js bump, or edit `EXTRA_LANGUAGES` to add a grammar:

```sh
cd glue/vendor && python3 vendor-hljs.py
```
