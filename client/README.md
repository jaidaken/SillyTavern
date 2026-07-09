---
description: the ziex + wasm SillyTavern client shell. build, export, and run it locally.
tags: [sillytavern, frontend, zig, wasm, ziex]
date: 2026-07-09
---

# client

The Zig/wasm frontend for this SillyTavern fork, built on [ziex](https://github.com/ziex-dev/ziex).
Chunk 1: the shell, the build wiring, and the JS door. No streaming, no markdown, no real API yet.

See [notes/frontend-stack.md](../notes/frontend-stack.md) for the stack decisions this implements.

## Requirements

Zig `0.16.0` (pinned in `.zigversion`). No npm, no node. The two vendored JS libraries are
copied from `../node_modules` and committed under `glue/vendor/`.

## Build

```sh
zig build                          # defaults to -Doptimize=ReleaseSmall
zig build -Doptimize=ReleaseSmall  # explicit
```

Output lands in `zig-out/`:

- `zig-out/static/assets/_/main.wasm` the client module (about 51 KB raw, 21 KB gzipped)
- `zig-out/static/glue/` our door: `main.js`, `app.css`, `vendor/`
- `zig-out/static/vendor/ziex/` ziex's compiled ESM door, installed via `client.jsglue_install_subdir`
- `zig-out/bin/st_client` the app binary, used at build time by the export step

`ReleaseFast` produces a roughly 1.08 MB wasm for no gain on a DOM-diffing chat UI. Keep `ReleaseSmall`.

## Export

```sh
zig build export
```

Runs `zig build -Dcli-command=export`, spawns `st_client` on a free loopback port, GETs every
route, and writes a static site to `dist/`. Everything under `zig-out/static/` is copied in.
`dist/` hydrates under any dumb static server; no ziex process is needed at runtime.

## Run

```sh
python3 devserve.py --port 8080
```

Serves `dist/` and reverse-proxies `/api/*` and `/csrf-token` to `http://127.0.0.1:8000`, so the
browser sees one origin and no CORS. Binds `127.0.0.1` only. Exits cleanly on SIGTERM.

Flags: `--port` (default 8080), `--dist` (default `dist`), `--backend` (default `http://127.0.0.1:8000`).

## Layout

```
build.zig             ziex.init wiring: jsglue_href, jsglue_install_subdir, export step
build.zig.zon         ziex pinned to rev 26f5945 (branch zig-0.16)
app/main.zig          ziex app entry
app/pages/layout.zx   html shell
app/pages/page.zx     the one route, renders ChatView
app/pages/chat.zx     ChatView, server-rendered, holds the message list
app/pages/message.zx  MessageView, one client component per message
app/pages/sanitized.zig  SanitizedHtml + the extern "env" host functions
app/pages/fixtures.zig   the three fixture messages
glue/main.js          the door: classic script, dynamic import, env namespace
glue/vendor/          purify.es.mjs, hljs.mjs, hljs-theme.css
devserve.py           static server + API reverse proxy
```

## The door

ziex injects `glue/main.js` as `<script defer src=...>` with no `type="module"`, so it is a
**classic script** and cannot use a top-level `import`. It dynamic-`import()`s ziex's ESM door,
DOMPurify, and highlight.js, then calls `init({ importObject: { env } })`. ziex merges the `env`
namespace into its own import object, so ziex itself is used unmodified with no fork.

`env` exposes three host functions to Zig:

- `sanitize(ptr, len)` runs `DOMPurify.sanitize()` with SillyTavern's message config.
- `render_code(ptr, len, lang_ptr, lang_len)` runs highlight.js, then DOMPurify.
- `sse_start(ptr, len)` a stub, wired but unused until chunk 2.

Each returns the result buffer packed as `(ptr << 32) | len`. The buffer is allocated with the
wasm module's own `__zx_alloc`, so **wasm owns it**.

### Sanitization is the security boundary

`@escaping={.none}` accepts only a `SanitizedHtml`, and its sole ergonomic constructors are
`sanitizeHtml` and `highlightCode`, both of which cross into `env` and come back through
DOMPurify. `SanitizedHtml` carries a witness pointer to a file-private `opaque` type, so a caller
in another file cannot write the struct literal:

```
error: missing struct field: witness_token
error: type '*const sanitized.Witness' does not support array initialization syntax
```

Zig has no field privacy, so this is not unforgeable: `.witness_token = undefined` compiles.
The property actually achieved is that raw bytes cannot reach `innerHTML` by accident or by any
ordinary construction, and any bypass has to name an obvious escape hatch that review can grep
for. That is worth having, but it is not a proof.

Beyond SillyTavern's current behaviour (`ADD_TAGS: ['custom-style']`, class namespacing to
`custom-<name>` except `fa-*` / `note-*` / `monospace`, forced `target="_blank" rel="noopener"`),
the door additionally rejects `javascript:` URIs and every `data:` URI whose mediatype is not an
image, including `image/svg+xml`.

### Why ChatView is the only client component

A client component requires a `<!--$id-->` comment marker in the served HTML, because
`Client.render` calls `document.findCommentMarker(cmp.id)` and returns `error.ContainerNotFound`
without one. Markers only exist in server-rendered or statically exported HTML, so a message
that arrives at runtime could never hydrate. Per-message client components make a dynamic
message list structurally impossible.

`ChatView` is therefore the single registered client component and owns all streamed state.
`scheduleRender(ChatView.id)` finds it in the registry, so the `renderAll()` fallback never
fires. Each message is a plain element with its own text node inside ChatView's vtree, so
appending to the last message writes only that message's bytes rather than re-sending the whole
log across the wasm boundary. No nested `ComponentCtx` holds state.

## Vendored JavaScript

`glue/vendor/purify.es.mjs` is copied verbatim from `dompurify` 3.4.11.

`glue/vendor/hljs.mjs` is **generated**. highlight.js 11.11.1 ships no browser ESM build: its
`es/index.js` re-exports `../lib/index.js`, which is CommonJS, and a browser importing it fails
with `SyntaxError: The requested module '../lib/index.js' does not provide an export named
'default'`. Since this tree may not run npm or webpack, `glue/vendor/vendor-hljs.py` walks
`require()` from an entry module, wraps each module's bytes verbatim in a function, and emits one
ESM file with a small CommonJS shim.

The entry is `lib/common.js` (36 languages) plus `nix`, not `lib/index.js` (all 192). Bundle
sizes, measured:

| set | raw | gzip |
|---|---|---|
| core only | 75,941 | 22,346 |
| core + common (36) | 367,215 | 97,963 |
| **core + common + nix (37)** | **378,003** | **100,330** |
| core + all (192) | 1,562,567 | 422,882 |

`highlightAuto` still runs, over the registered set; only the size of that set changes. The 37
cover what a model realistically emits into a chat. **highlight.js ships no Zig grammar**, so
Zig code blocks fall back to plaintext.

Regenerate after a highlight.js bump, or edit `EXTRA_LANGUAGES` to add a grammar:

```sh
cd glue/vendor && python3 vendor-hljs.py
```
