---
description: Read-only audit of the client build, dev, verify and deploy tooling (build.sh, setup-ziex.sh, patch-door.sh, prune-dist.sh, dev-tunnel.sh, devserve.py, verify.sh, build.zig, patches/). W05 workstream, 2026-07-10.
tags: [audit, client, tooling, build, verify, devserve, ziex, wasm]
date: 2026-07-10
---

# W05: build / dev / deploy tooling audit (2026-07-10)

Scope: every script in `client/` read as source, none executed. `client/build.sh`,
`client/setup-ziex.sh`, `client/patch-door.sh`, `client/prune-dist.sh`, `client/dev-tunnel.sh`,
`client/devserve.py`, `client/verify.sh`, `client/build.zig`, `client/build.zig.zon`,
`client/patches/*`, `client/README.md`. 8 of 8 script files covered. No deploy script exists in the
tree (see `## deploy`).

Counts used below for `verify.sh` are derived two ways: pre-hydration counts read directly out of the
committed `dist/index.html` (built 2026-07-10 14:47), and post-hydration DOM counts derived from
`app/pages/fixtures.zig` + `app/pages/chat.zx` + `app/pages/markdown.zig` (`MD_DIALECT_GITHUB |
MD_FLAG_HARD_SOFT_BREAKS`) + `app/pages/quotes.zig`. No browser was launched.

Severity: BUG = wrong or breaks behaviour. DRIFT = doc or comment disagrees with code. NIT = cosmetic
or hardening. QUESTION = needs a human decision.

Index line for `client/notes/README.md` is owed (that file does not exist yet); this member writes
only its own findings file.

## verify.sh failing checks

`verify.sh` increments `FAILURES` once per failing `check`/`atleast` call and once per failing inline
python block. On a clean HEAD tree with a correct build, **15 increments** fire. The three demo
sections were removed from `ChatView` (`chat.zx:44` renders `fixtures.sections[0].messages[0..3]`),
so every assertion written against the old 7-message 4-section demo now asserts absent content.

Shell-granularity list (the 15):

1. `verify.sh:60` `ssr placeholder, one per message` - `check ... 7`. Actual `dist/index.html` has 3
   `ST_SSR_PLACEHOLDER`. got 3, want 7. Cause: 3 messages SSR'd, not 7.
2. `verify.sh:66` `messages rendered` - `check ... 7`. DOM has 3 `class="mes"`. got 3, want 7.
3. `verify.sh:67` `demo sections` - `check ... 4`. `class="demo"` no longer exists in any component.
   got 0, want 4.
4. `verify.sh:74` `png data uri preserved` - `check ... 1`. The `data:image/png` payload lives in
   `fixtures.zig:114` (`security` section), never rendered. got 0, want 1.
5. `verify.sh:75` `author class namespaced` - `check ... 1`. `class="danger"` lives in
   `fixtures.zig:111` (`security` section), never rendered. got 0, want 1.
6. `verify.sh:76` `rel=noopener forced on links` - `atleast ... 2`. The only anchors are in the
   `security` section. got 0, want >= 2.
7. `verify.sh:80` `headings` - `atleast '<h1>' 1`. Headings live in `markdown_showcase`, never
   rendered. got 0, want >= 1.
8. `verify.sh:81` `blockquotes` - `atleast '<blockquote>' 2`. Only `fixtures.zig:29` (`> The parchment
   smells of salt and old smoke.`) survives. got 1, want >= 2.
9. `verify.sh:82` `tables` - `atleast '<table>' 1`. Tables live in `markdown_showcase`. got 0, want >= 1.
10. `verify.sh:83` `hard line breaks` - `atleast '<br' 3`. Only `fixtures.zig:35-36` ("Her jaw
    tightens." / "She rolls the map closed...") is a softbreak inside a paragraph. got 1, want >= 3.
11. `verify.sh:84` `task list items` - `atleast 'task-list-item' 2`. Task lists live in
    `markdown_showcase`. got 0, want >= 2.
12. `verify.sh:89` `quotes wrapped` - `atleast '<q>' 11`. The 3 rendered messages carry 4 quoted spans
    ("You're late...", "What is that?", "A wreck. Three days old.", "And **not** ours."). got 4,
    want >= 11.
13. `verify.sh:101` `hljs token spans` - `atleast 'class="hljs-' 10`. No fenced code block is rendered
    (the `Quote styles` message that has one is `messages[3]`, sliced off by `chat.zx:44`). got 0,
    want >= 10.
14. `verify.sh:141` the streaming python block exits 1. Root cause is the `devserve.py:96` SSE shape
    bug below, so `/dev/stream` yields zero tokens. Sub-checks inside it:
    - `verify.sh:132` `all tokens delivered` - `s["tokens"] == 200`. `stats.tokens` is set from
      `wasm.__st_stream_tokens()` (`glue/main.js:299`), the Zig-side counter. got 0, want 200.
    - `verify.sh:136` `render cache holds` - budget `8 + flushes + 2` is derived from the comment at
      `verify.sh:134` ("7 fixtures at boot"). Only 3 fixtures boot now, so the budget is stale even
      though it still passes (it is an upper bound).
    - `verify.sh:137` `tail text present` - `"tok199" in h`. got absent.
    - `verify.sh:138` `streamed message appended` - `len(class="mes") == 8`. Actual is 4 (3 fixtures +
      1 streamed). got 4, want 8.
    - `verify.sh:133` `writes coalesced per frame` (`flushes < 60`) passes vacuously at 0 flushes.
15. `verify.sh:166` the two-consecutive-streams python block exits 1. Same root cause: with 0 tokens
    delivered, neither `aaa0` nor `bbb0` reaches the DOM.
    - `verify.sh:158` prints FAIL for both `First message owns its tokens` and `Second message owns
      its tokens` (`aaa=False bbb=False` against wants `(True,False)` / `(False,True)`), so 2 python
      sub-failures collapse into 1 shell increment.

Checks that PASS today but assert nothing (they would also pass against a completely broken
sanitizer, because the hostile fixtures are no longer rendered). These are not in the 15, and any
`verify.sh` rewrite must restore real inputs for them:

- `verify.sh:71` `onerror attribute stripped` - `check ... 0`. No `onerror` is rendered.
- `verify.sh:72` `javascript: href stripped` - `check ... 0`. No anchor is rendered.
- `verify.sh:73` `svg data uri stripped` - `check ... 0`. No `<img>` is rendered.
- `verify.sh:88` `q opens and closes balance` - `4 == 4`, trivially true.
- `verify.sh:90-96` `q inside code or pre` - no `<code>`/`<pre>` renders, so the leak scan sees nothing.
- `verify.sh:102` `no namespaced hljs classes` - `check ... 0`. No hljs output exists.
- `verify.sh:59` `hydration markers in index.html` - `1`, correct (ChatView is the only client
  component).
- `verify.sh:55` `door patched, no stringCache` - `0`, correct after `patch-door.sh` ran.
- `verify.sh:111` `/dev/stream 404 without --dev` - correct.

## devserve.py

- [BUG] `devserve.py:96` - `self.wfile.write(f"data: {prefix}{i} \n\n".encode())` emits a bare token
  as the SSE payload. `app/pages/completion.zig:25` rejects any payload whose first byte is not `{`
  (`if (trimmed[0] != '{') return .empty;`), so `/dev/stream` delivers 0 tokens to the store. The
  entire streaming half of `verify.sh` therefore fails, and any manual `?stream=1` probe shows an
  empty streamed message. One-line fix (plus `import json` at the top): replace line 96 with
  `self.wfile.write(f"data: {json.dumps({'content': f'{prefix}{i} '})}\n\n".encode())`. `json.dumps`
  is required rather than an f-string literal because `prefix` is attacker-free but arbitrary
  (`?prefix=a"b` would otherwise emit invalid JSON, which `parsePayload` swallows as `.empty`, hiding
  the failure). The trailing space inside the JSON string must be preserved: it is how tokens join.
  `devserve.py:99` (`data: [DONE]`) is already correct against `completion.zig:24`.
- [BUG] `devserve.py:147` - `payload = upstream.read()` buffers the whole upstream response before
  `relay` writes a byte. SillyTavern's real streaming endpoint (`POST
  /api/backends/text-completions/generate` with `stream: true`) is proxied through here, so the
  browser receives every token at once, after generation finishes. The dev server cannot exercise the
  client's real streaming path against the real backend at all; only the synthetic `/dev/stream`
  route streams. Relay incrementally (`shutil.copyfileobj` with a small buffer + `flush`, no
  `Content-Length`) for proxied `text/event-stream` responses.
- [BUG] `devserve.py:134` - `urllib.request.urlopen(req)` has no `timeout`. A backend that accepts the
  connection and never answers pins a handler thread forever. `ThreadingTCPServer` with
  `daemon_threads` hides it until the port pool starves.
- [NIT] `devserve.py:86-88` - `int(params.get("n", ["200"])[0])` and `float(params.get("delay",...))`
  are unvalidated. `?n=abc` raises `ValueError` inside the handler, which
  `SimpleHTTPRequestHandler` turns into a 500 plus a traceback on stderr rather than a 400. `?n=-1`
  silently yields an empty stream, which reads identically to the `:96` bug above.
- [NIT] `devserve.py:72` - `time.sleep(min(float(...) / 1000.0, 30.0))` has an upper clamp and no
  lower clamp. `?ms=-1` raises `ValueError` from `time.sleep`.
- [NIT] `devserve.py:42` - `Handler.dist` is read in `__init__` but never declared as a class
  attribute; it only exists after `main()` assigns it at `devserve.py:174`. `backend` and `dev` at
  `:38-39` do have defaults. Importing this module and instantiating `Handler` without `main()`
  raises `AttributeError`.
- [NIT] `devserve.py:24` - `PROXY_PREFIXES = ("/api/", "/csrf-token")`. The second entry is a prefix,
  not an exact match, so `/csrf-token-anything` is also proxied. Harmless against the current
  backend, but it is the only thing standing between `urljoin` at `:126` and a network-path reference:
  a request-target of `//evil.example/api/x` would make `urljoin("http://127.0.0.1:8000", ...)` return
  `http://evil.example/api/x`. Today `startswith("/api/")` rejects it. Tighten to an exact match on
  `/csrf-token` and an explicit `not self.path.startswith("//")` guard so the safety does not rest on
  a coincidence.
- [NIT] `devserve.py:128-131` - every client header except hop-by-hop and `Host` is forwarded,
  including `Cookie` and `Authorization`. `--backend` is operator-supplied and unvalidated, so
  `--backend http://someone-else` forwards the ST session cookie off-box. Bind is loopback so the
  exposure needs an operator mistake, not a remote one.
- [NIT] `devserve.py:153` - `log_message` prints method and path but never the status code, so a 502
  or a 404 is invisible in the log line.
- [DRIFT] `devserve.py:8` - the docstring usage line omits `--dev`, which `:167` defines and
  `verify.sh:43` depends on.

## verify.sh

- [BUG] `verify.sh:60,66,67,74,75,76,80,81,82,83,84,89,101` - 13 assertions describe the deleted demo
  page. See `## verify.sh failing checks`. Consequence: the regression gate is red on a known-good
  tree, so it can no longer detect a real regression; anyone running it learns nothing.
- [BUG] `verify.sh:71,72,73,88,90-96,102` - 7 assertions now pass vacuously because their hostile
  inputs are not rendered. A sanitizer that stripped nothing, or one that stripped everything, would
  still pass this section. This is the "silently passes a broken build" hole in the gate: the sanitize
  boundary, the quote-in-code leak scan, and the hljs namespacing check all have zero inputs.
- [BUG] `verify.sh:55` - `check "door patched, no stringCache" ... 0` asserts the ABSENCE of the cache
  marker. `patch-door.sh:33-34` explicitly documents that absence is not proof: "a reformatted or
  minified door has both markers absent while still carrying the D1 bug." The gate contradicts the
  patch script's own stated invariant. Assert the PRESENCE of the uncached body
  (`return textDecoder.decode(getMemoryView().subarray(ptr, ptr + len));`) instead.
- [BUG] `verify.sh:48` - `google-chrome-stable` is hardcoded with no existence check. If it is absent
  the `timeout 60` call exits 127, `$DOM` is empty, and every DOM check reports `got 0, want N`, which
  reads exactly like a real regression. Probe for the binary and fail with a named message.
- [BUG] `verify.sh:39-40` - the preflight requires `dist/index.html` and the door but never checks
  `dist/assets/_/main.wasm`. A dist with no wasm still passes the preflight and then fails 15 DOM
  checks with no indication that the module is missing.
- [BUG] `verify.sh` (whole file) - nothing in this tree ever runs `zig build test` or `zig build
  check`. `build.sh:12-14` runs neither, and this script is described as the gate. A tree with failing
  unit tests and unformatted source builds green and gates green.
- [NIT] `verify.sh:43,106` - the server is started and then `sleep 2`; readiness is assumed, never
  polled. On a loaded box, or with `PORT=8899` already bound (the bind failure is swallowed by
  `>/dev/null 2>&1`), the first chrome load hits nothing and 15 checks fail for the wrong reason.
  Poll the port, and do not discard the server's stderr.
- [NIT] `verify.sh:106-110` - `NODEV` is spawned but never added to the EXIT trap (only `SRV` is, at
  `:15`). An interrupt between `:106` and `:110` leaves it running until its own `timeout 20` fires.
- [NIT] `verify.sh:109` - `curl -sS` with no `--max-time`. A hung server hangs the whole gate; the
  only bound is the `timeout 20` on the server itself.
- [NIT] `verify.sh:15` - `kill -TERM "$SRV"` targets the `timeout` process. `setsid` puts it in a new
  session, so a `SIGKILL` of `verify.sh` orphans the server for up to the full `timeout 300`. Kill the
  process group instead.
- [NIT] `verify.sh:37` - `DOOR="dist/vendor/ziex/wasm/index.js"` duplicates the default in
  `patch-door.sh:8`. Two owners of one path; a move breaks the gate silently (it exits 1 at `:40`,
  which reads as "run export first").
- [NIT] `verify.sh:161-163` - `if len(msgs) < 2` cannot fire: the regex at `:149` matches every
  message including the 3 fixtures, so the guard is satisfied before either streamed message exists.
  Match on the `First`/`Second` names instead.
- [NIT] `verify.sh:149` - the regex requires `</div><div class="mes_text"` with no intervening
  whitespace. The planned a11y change (backlog: `message.zx:13`, wrap messages in `<article>`) will
  silently zero this match set.
- [NIT] `verify.sh:174` - `exit "$FAILURES"` wraps modulo 256. 256 failures would exit 0. Cap at 1.
- [DRIFT] `verify.sh:42` - "two sleeps plus three chrome loads capped at 60s each, so the server must
  outlive 182s." Two sleeps of 2s plus three 60s caps is 184s, not 182s.
- [DRIFT] `verify.sh:134` - "7 fixtures at boot" in the sanitize-budget comment. 3 fixtures boot.
- [DRIFT] `verify.sh:2-3` - the header calls this the gate for "hydration, the sanitize boundary, the
  render cache, and streaming". Two of those four (sanitize boundary, streaming) currently assert
  nothing or assert against a broken producer.

## build.sh

- [BUG] `build.sh:12-14` - runs `zig build`, `zig build export`, `patch-door.sh`, and never `zig build
  test` or `zig build check` (both exist, `build.zig:40,63`). The full build script is green on a tree
  whose unit tests fail. Given `build.sh:16` points the operator at `verify.sh`, and `verify.sh` does
  not run them either, the Zig test suite is not wired into any path a human takes.
- [BUG] `build.sh:14` - `prune-dist.sh` is never invoked, by this script or any other. `prune-dist.sh:2`
  says "zx export copies the whole ziex npm tree into dist/", so every `dist/` this script produces
  carries the unpruned tree. Whatever the deploy actually ships is therefore either unpruned or
  pruned by an unrecorded manual step.
- [NIT] `build.sh:11` - `./setup-ziex.sh` runs unconditionally and, on a fresh tree, requires network
  (`git clone` from github). There is no offline path and no message saying network is needed.
- [NIT] `build.sh:8` - `OPT="${OPT:-ReleaseSmall}"` is interpolated straight into `-Doptimize=$OPT`.
  A typo fails at the zig layer with a zig error, which is acceptable, but `README.md:33` states the
  ReleaseFast tradeoff and nothing enforces the default.
- [NIT] `build.sh` - no `zig version` assertion against `.zigversion` (`0.16.0`). `build.zig.zon:5`
  sets `minimum_zig_version` so a too-old zig fails, but a too-new zig with breaking std changes fails
  with a compile error deep in ziex.

## setup-ziex.sh

- [BUG] `setup-ziex.sh:32` - the glob loop applies `01-*`, `02-*`, `04-*` and deliberately skips
  `03-*`. `patches/03-readstring-cache-stale-leak.patch` is therefore applied by NOTHING:
  `patch-door.sh` re-implements the same edit as two hardcoded string literals
  (`patch-door.sh:15-31`). There is no check that the patch file and the hardcoded strings stay in
  agreement. Edit one, the other silently rots, and `patches/README.md:11` still lists 03 as one of
  "four fixes ... applied to the fetched ziex source before build", which is false.
- [NIT] `setup-ziex.sh:32` - no `shopt -s nullglob`/`failglob`. If a patch file is renamed, bash passes
  the unexpanded pattern to `git apply`, which fails with "No such file or directory" under `set -e`.
  Loud, but the message names a glob, not a missing patch.
- [NIT] `setup-ziex.sh:32` - a second file matching `01-*` would be applied too, silently.
- [NIT] `setup-ziex.sh:33` - `git -C "$ZIEX_DIR" apply "../$p"` hardcodes the assumption that
  `$ZIEX_DIR` is exactly one directory below the script. `ZIEX_DIR=".ziex"` today; any nesting breaks
  it. Use `"$PWD/$p"`.
- [NIT] `setup-ziex.sh:13-21` - the reuse branch keys only on `HEAD == $ZIEX_REV`. A `.ziex` clone
  whose `origin` was repointed at a different fork with a colliding rev would be reused. Verify
  `git -C .ziex remote get-url origin` too.
- [NIT] `setup-ziex.sh:25` - `git clone` over https with no `--depth`, no submodule handling, and no
  verification beyond the pinned SHA. The full-SHA checkout is the pin, which is sound; the missing
  half is that nothing records the expected tree hash, so a rewritten history under the same SHA is
  impossible but a compromised github serving a different object for that SHA is only prevented by
  git's own hash check (sha1, collision-resistant enough here).
- [DRIFT] `setup-ziex.sh:3` vs `:30-31` - the header says "the door patch (D1) is in the prebuilt
  tarball, not source"; the loop comment says "03 is the upstream core.ts diff". Both are true and
  both name the same patch differently (D1 / 03). One name.

## patch-door.sh

- [NIT] `patch-door.sh:13,44` - `p.read_text()` / `p.write_text()` use the locale default encoding.
  Under `LC_ALL=C` (a plausible CI or nix build env) a non-ASCII byte anywhere in the door raises
  `UnicodeDecodeError`. Pass `encoding="utf-8"` to both.
- [NIT] `patch-door.sh:15-31` - the search string is a 13-line verbatim block including exact
  two-space indentation. Any reformat of the door (prettier, a ziex release built with different
  emit settings) makes it not match, and `:39-42` then exits 1 with the correct message. This is the
  right failure mode, but there is no version assertion tying the strings to the pinned ziex rev
  (`26f594531d302421f4e53b52c9b3c653093c1392`, `setup-ziex.sh:8`). Print the rev in the failure text.
- [NIT] `patch-door.sh:8` - the `$1` override exists but no caller uses it (`build.sh:14` passes
  nothing, `verify.sh:37` keeps its own copy of the path). Dead parameter or an undocumented hook.
- [DRIFT] `patch-door.sh:2` - "Apply D1 ... The door ships as a prebuilt tarball, so patch 03's core.ts
  diff never reaches the build." Accurate, and it is the clearest statement of the `patches/03` dead-
  file problem above. `patches/README.md:11` contradicts it.

## prune-dist.sh

- [BUG] `prune-dist.sh` (whole file) - not called from `build.sh`, `verify.sh`, or anything else in
  the tree. It is a manual step with no recorded caller, and `verify.sh` runs against an unpruned
  `dist/`. So the artifact the gate verifies is never the artifact that would be deployed.
- [BUG] `prune-dist.sh:12-22` - `KEEP` is asserted to be exhaustive ("only these paths are ever
  fetched", `:2`), but nothing verifies that after the prune. If ziex's door ever dynamic-imports a
  sibling module, `rm -f` deletes it and the failure appears only in a browser console, at runtime,
  in whatever the deploy is. Re-run `verify.sh` against the pruned tree, or diff a browser network log.
- [NIT] `prune-dist.sh:33` - `sed 's/[.[\*^$]/\\&/g'` escapes BRE metacharacters, but the result is
  consumed by `grep -qE` at `:38` (ERE). `+ ? ( ) { } |` are special in ERE and go unescaped. No
  current `KEEP` entry contains one, so it is latent.
- [NIT] `prune-dist.sh:24-28,43-47` - the gzip accounting forks `gzip -9` once per file, twice (before
  and after). On the unpruned ziex npm tree that is thousands of processes for a log line.
- [NIT] `prune-dist.sh:36-39` - `find -type f` ignores symlinks, so a symlinked file survives the prune
  and its parent directory survives `-type d -empty -delete` at `:41`. npm trees contain symlinks.
- [NIT] `prune-dist.sh:8` - the trailing-slash strip loop is correct and well-commented, but `DIST=".."`
  or `DIST="$HOME"` passes every guard at `:9-10` and would delete the caller's tree. Anchor the
  argument (require it to contain `dist`, or resolve it and require it under the script's directory).

## dev-tunnel.sh

- [BUG] `dev-tunnel.sh:10` - `exec ssh -N -L "${LOCAL_PORT}:127.0.0.1:8000" silly` omits
  `-o ExitOnForwardFailure=yes`. If `8143` is already bound, ssh prints a warning to stderr, keeps the
  session up with no forward, and the script looks healthy. `devserve.py --backend
  http://127.0.0.1:8143` then talks to whatever else owns that port, or gets connection-refused, and
  the operator debugs the wrong layer.
- [NIT] `dev-tunnel.sh:10` - no `-o ServerAliveInterval=30 -o ServerAliveCountMax=3`. A dropped LAN
  link leaves a dead tunnel that accepts connections and never answers.
- [NIT] `dev-tunnel.sh:7` - `LOCAL_PORT` is unvalidated and interpolated into the `-L` spec.
- [DRIFT] `dev-tunnel.sh:9` vs `devserve.py:166` - the tunnel tells you to pass
  `--backend http://127.0.0.1:8143`; `devserve.py` defaults to `:8000`. Correct as written, but the
  two defaults disagree and nothing wires them together. `README.md:49-56` documents `devserve.py` and
  never mentions `dev-tunnel.sh`.
- [QUESTION] `dev-tunnel.sh:2` - the comment names the deploy host (`.43`) and the unlock path
  (`silly.jaidaken.dev`). No secret is stored here; the tunnel relies entirely on the operator's ssh
  agent and the `silly` host alias. Confirm the `silly` alias is expected to exist for anyone who ever
  builds this tree, or gate the script on `ssh -G silly`.

## build.zig

- [NIT] `build.zig:33` - `app_exe.step.dependOn(&install_glue.step)` makes the compile of the wasm
  module depend on an install-directory step. `b.getInstallStep().dependOn(...)` at `:35` already
  guarantees the copy on `zig build`. The extra edge forces the glue copy before every compile,
  including `zig build test`, and reverses the normal artifact-before-install direction. If the intent
  is "the export step must see glue", say so; otherwise drop the edge.
- [NIT] `build.zig:86` - `-DNDEBUG` is applied to `.flags` for every consumer, including the Debug test
  module built at `:42-49`. md4c's internal asserts are compiled out of the test build, so the
  alloc-failure oracle described in the comment at `:38-39` runs against an assert-free md4c.
- [NIT] `build.zig:61-63` - the `check` step (`zig fmt --check`) exists and nothing runs it. Its path
  set is `{"app", "build.zig"}`, so `build.zig.zon`, `glue/`, and the python are unformatted by
  policy.
- [NIT] `build.zig:42-46` - the test module inherits `standardTargetOptions`. `zig build test
  -Dtarget=wasm32-freestanding` produces a test binary the host cannot run; the failure is a confusing
  exec error rather than a named refusal.
- [NIT] `build.zig:88-90` - `addMd4c` calls `b.createModule` for `libc_shim` on every invocation, so
  the app's md4c module and the test module each get a distinct `libc_shim` module instance. Correct
  today (they land in different compilations), but a future `addMd4c(b, some_module_linked_into_the_exe)`
  would give one binary two copies of `libc_shim`'s globals.
- [DRIFT] `build.zig:22` vs `README.md` layout block - `README.md:64` lists `app/pages/fixtures.zig`
  as "the three fixture messages"; it holds three SECTIONS (`fixtures.zig:124`) of which only
  `sections[0].messages[0..3]` renders.

## README.md

- [BUG] `README.md:20-24` - the documented build is `zig build`. `build.zig.zon:8` and `build.sh:2-3`
  both say the opposite: bare `zig build` produces a client with none of the four ziex patches (two
  use-after-free / handle-leak fixes, the render marker leak, and the door's `stringCache` stale-read).
  A reader who follows the README ships a knowingly broken build and `verify.sh:55` is the only thing
  that would catch the door half of it.
- [DRIFT] `README.md:9` - "Chunk 1: the shell, the build wiring, and the JS door. No streaming, no
  markdown, no real API yet." All three exist (`glue/main.js:206` `startStream`,
  `app/pages/markdown.zig`, `app/pages/completion.zig`).
- [DRIFT] `README.md:63` - "app/pages/message.zx MessageView, one client component per message."
  `message.zx:6-8` documents the exact opposite, and `README.md:102-112` then explains why per-message
  client components are impossible. The layout table contradicts the prose two screens below it.
- [DRIFT] `README.md:93` - "`sse_start(ptr, len)` a stub, wired but unused until chunk 2."
  `glue/main.js:187` calls `startStream` from it.
- [DRIFT] `README.md` - `build.sh`, `setup-ziex.sh`, `patch-door.sh`, `prune-dist.sh`, `verify.sh`,
  `dev-tunnel.sh` and `patches/` are absent from the layout block and from the build instructions.

## deploy

- [QUESTION] no deploy script exists under `client/`. The only shell scripts are the six audited above,
  none of which copy anything off-box, and `grep -rn "client/dist"` across the repo returns nothing.
  The tar-over-ssh publish to the static host is therefore an unrecorded manual command. Combined with
  `.gitignore:4` (`dist/`), nothing establishes that the bytes deployed were produced by `build.sh`
  (patched door, `patch-door.sh` applied) rather than by the README's bare `zig build` (unpatched), and
  nothing establishes they were pruned. Record the deploy as a script, and have it refuse a `dist/`
  whose door still contains `stringCache`.
- [QUESTION] `prune-dist.sh` + `patch-door.sh` both mutate `dist/` in place and must run in a fixed
  order relative to `zig build export` (export, then patch-door, then prune). `build.sh` encodes two
  of the three. The third is a human's memory.

## Cross-cutting: what would silently pass a broken build

1. Failing Zig unit tests. Nothing runs `zig build test`.
2. Unformatted source. Nothing runs `zig build check`.
3. A sanitizer that strips nothing. `verify.sh:71-73` have no hostile input to strip.
4. A quote wrapper that leaks `<q>` into `<pre>`. `verify.sh:90-96` has no `<pre>` to inspect.
5. An hljs namespacing regression. `verify.sh:102` has no hljs output to inspect.
6. A reformatted-but-unpatched ziex door. `verify.sh:55` checks marker absence, which
   `patch-door.sh:33-34` documents as insufficient.
7. A `dist/` missing `main.wasm`. Nothing asserts it exists; the failure surfaces as 15 wrong-looking
   DOM failures.
8. A `patches/03` that has drifted from `patch-door.sh`'s hardcoded strings. Nothing compares them.
9. A `dist/` pruned of a file ziex actually fetches. Nothing re-verifies after `prune-dist.sh`.
10. A deployed build made with bare `zig build`. No deploy script, no door assertion at publish time.
