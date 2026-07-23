#!/usr/bin/env bash
# End-to-end regression gate: zig fmt + unit tests, then the served three-region DOM, the sanitize
# boundary, markdown + highlighting, the render cache, and streaming, all against a real browser.
# The three rendered fixtures are roleplay prose, so the hostile and markdown vectors are NOT among
# them; this gate drives them through the real pipeline (quotes -> md4c -> DOMPurify) via a custom
# /dev/stream?prefix= URL, so a sanitizer or highlighter regression actually fails a check.
# Usage: ./verify.sh   (expects ./build.sh already run: patched door + pruned dist)
set -uo pipefail

cd "$(dirname "$0")"

PORT="${PORT:-8899}"
FAILURES=0
# The verdict needs a denominator: "all checks passed" reads exactly the same whether every row
# passed or no row ran at all, and a runner that cannot tell those apart has no way to notice a
# stage that died before its first assertion.
ROWS=0
PASSES=0
DOM=$(mktemp)
SAN_DOM=$(mktemp)
MD_DOM=$(mktemp)
STREAM_DOM=$(mktemp)
HIST_JSON=$(mktemp)
PROFILE=$(mktemp -d)
SRV=""
NODEV=""
HISTSRV=""
cleanup() {
    # setsid makes each server its own process-group leader, so a group kill reaps the timeout
    # wrapper, python, and its handler threads together; a bare kill would orphan them.
    [ -n "$SRV" ] && kill -TERM -- -"$SRV" 2>/dev/null
    [ -n "$NODEV" ] && kill -TERM -- -"$NODEV" 2>/dev/null
    [ -n "$HISTSRV" ] && kill -TERM -- -"$HISTSRV" 2>/dev/null
    rm -rf "$DOM" "$SAN_DOM" "$MD_DOM" "$STREAM_DOM" "$HIST_JSON" "$PROFILE" "${TALLY:-}"
}
trap cleanup EXIT

check() {
    local label="$1" actual="$2" expected="$3"
    ROWS=$((ROWS + 1))
    if [ "$actual" = "$expected" ]; then
        printf '  ok    %-52s %s\n' "$label" "$actual"
        PASSES=$((PASSES + 1))
    else
        printf '  FAIL  %-52s got %s, want %s\n' "$label" "$actual" "$expected"
        FAILURES=$((FAILURES + 1))
    fi
}

atleast() {
    local label="$1" actual="$2" floor="$3"
    ROWS=$((ROWS + 1))
    if [ "$actual" -ge "$floor" ]; then
        printf '  ok    %-52s %s (>= %s)\n' "$label" "$actual" "$floor"
        PASSES=$((PASSES + 1))
    else
        printf '  FAIL  %-52s got %s, want >= %s\n' "$label" "$actual" "$floor"
        FAILURES=$((FAILURES + 1))
    fi
}

# The python stages below print their own rows and can only hand back an exit code, so a stage that
# dies before its first row (a SyntaxError, a missing input) would otherwise cost the denominator
# nothing and read as one failure out of a total that already excluded the rows it never ran. Each
# writes "<rows> <passes>" here from the same counters that decide its exit, and a stage that leaves
# the file empty is counted as a stage that ran nothing.
TALLY=$(mktemp)
tally() {
    local label="$1" rc="$2" rows passes
    read -r rows passes < "$TALLY" 2>/dev/null || true
    : > "$TALLY"
    if [ -z "${rows:-}" ]; then
        printf '  FAIL  %-52s stage reported no rows (rc=%s)\n' "$label" "$rc"
        ROWS=$((ROWS + 1)); FAILURES=$((FAILURES + 1))
        return
    fi
    ROWS=$((ROWS + rows))
    PASSES=$((PASSES + passes))
    FAILURES=$((FAILURES + rows - passes))
}

count() { grep -o "$1" "$2" 2>/dev/null | wc -l; }

# A readiness curl proves that A server answers on this port, never that it is OURS. A concurrent
# gate holding the port answers the very first poll, our own python3 dies of EADDRINUSE unnoticed,
# and every row then drives the STRANGER's dist and mock while reporting on ours. Refusing a port
# that already answers closes the common case but still cannot prove the server we go on to poll is
# the one we launched, so the readiness loops below ask the kernel who is actually listening.
port_answers() { curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$1/" 2>/dev/null; }

refuse_taken_port() {
    local port="$1" what="$2"
    port_answers "$port" || return 0
    echo "port $port already answers and we have not started yet: another run holds it ($what)." >&2
    echo "concurrent gates must not share ports: pass a free PORT (it also uses PORT+1, PORT+2)." >&2
    echo "find a stale server with: ps -eo pid,cmd | grep '[d]evserve'   (no fuser on NixOS, never a broad pkill)" >&2
    exit 1
}

# setsid makes the launched wrapper its own group leader, so everything it spawns carries its pid as
# the PGID: the listener being in that group is proof the socket is ours and not a survivor of it.
owns_port() {
    local pgid="$1" port="$2" lpid
    lpid=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
    [ -n "$lpid" ] || return 1
    [ "$(ps -o pgid= -p "$lpid" 2>/dev/null | tr -d ' ')" = "$pgid" ]
}

DOOR="dist/vendor/ziex/wasm/index.js"
CUSTOM="dist/glue/custom.js"
WASM="dist/assets/_/main.wasm"

# Preflight. A missing artifact must name itself, not surface later as a browser check that reads
# exactly like a real regression (empty DOM, everything zero).
[ -f dist/index.html ] || { echo "no dist/index.html: run ./build.sh first" >&2; exit 1; }
[ -f "$DOOR" ] || { echo "no $DOOR: run ./build.sh first" >&2; exit 1; }
# Named for the same reason as the door: a missing file would read as a guard that failed to survive
# minification, which is a different and much more alarming thing than a build that never ran.
[ -f "$CUSTOM" ] || { echo "no $CUSTOM: run ./build.sh first" >&2; exit 1; }
[ -f "$WASM" ] || { echo "no $WASM: the wasm module is missing, run ./build.sh first" >&2; exit 1; }
command -v google-chrome-stable >/dev/null 2>&1 || {
    echo "google-chrome-stable not on PATH: the browser gate cannot run" >&2; exit 1
}
# render.mjs drives Chrome over CDP with Node's global WebSocket + fetch. Test the capability, not a
# version string: they are stable in Node 22+, and this project pins >=26.
command -v node >/dev/null 2>&1 || { echo "node not on PATH: render.mjs cannot run" >&2; exit 1; }
node -e 'process.exit(typeof WebSocket==="function"&&typeof fetch==="function"?0:1)' 2>/dev/null || {
    echo "node lacks global WebSocket/fetch (need >=22; project pins >=26): render.mjs cannot run" >&2; exit 1
}
# owns_port asks ss who holds the socket. Without it every readiness poll is back to trusting that an
# answer came from our own server, so this is a hard requirement, not a nice-to-have.
command -v ss >/dev/null 2>&1 || { echo "ss not on PATH: cannot prove we own our ports" >&2; exit 1; }

echo "== zig gates =="
if zig build check; then check "zig fmt --check" pass pass; else check "zig fmt --check" fail pass; fi
if zig build test;  then check "zig build test"  pass pass; else check "zig build test"  fail pass; fi

echo
echo "== build artifacts =="
# The door is minified, so grep minify-stable signals not the source line: the decode path survives
# (property names are not mangled) and the D1 patch removed stringCacheKey (the door's only 65536).
atleast "door readString decode path present" "$(count 'subarray(' "$DOOR")" 1
check   "door patched: string cache removed (D1)" "$(count '65536' "$DOOR")" 0
check   "main.wasm present" "$([ -f "$WASM" ] && echo yes || echo no)" "yes"
# Both files are minified AFTER they are patched, so a guard that esbuild drops is a guard that never
# ships and the [zx:dom] rows in the interaction gate would go quiet without ever going red. esbuild
# --minify keeps a string literal verbatim (probed directly: it survives both hoisted and inline), so
# a zero here means the emitter is missing, not that the minifier ate it.
atleast "door emits the [zx:dom] guard after minify" "$(count '\[zx:dom\]' "$DOOR")" 1
atleast "glue custom.js emits the [zx:dom] guard after minify" "$(count '\[zx:dom\]' "$CUSTOM")" 1

echo
echo "== served html (pre-hydration) =="
# Five client regions (Shell, MessageLog, Home, Composer, Toasts), each with one SSR marker; three
# fixtures, each body a placeholder the client replaces.
check "region hydration markers in index.html" "$(count '<!--\$' dist/index.html)" 5
# 24 = two sinks per fixture message: the body and the reasoning block (w3-reason), which always
# renders (hidden when empty) so mid-stream appearance never needs a structural vdom insert.
check "ssr placeholder, two per message (body + reasoning)" "$(count 'ST_SSR_PLACEHOLDER' dist/index.html)" 24
# The justify gate (message.zx): long messages carry mes-justify, short roleplay turns stay plain, so
# both classes must appear in the SSR. A regression that justified everything (or nothing) fails here.
atleast "justify gate: long messages carry mes-justify" "$(count 'class=\"mes_text mes-justify\"' dist/index.html)" 1
atleast "justify gate: short messages stay plain mes_text" "$(count 'class=\"mes_text\"' dist/index.html)" 1

# Start the server for every browser check. --dev exposes /dev/stream and /dev/hold. setsid so the
# whole tree dies with the group kill in cleanup.
refuse_taken_port "$PORT" "the dev server"
setsid timeout -k 5 320 python3 devserve.py --port "$PORT" --dist dist --dev >"$PROFILE/srv.log" 2>&1 &
SRV=$!
# Ready means OUR server answers. Curl alone cannot say that, and the failure it hides is not a
# missing server but a stranger's: the rows all pass or fail against someone else's tree.
ready=no
for _ in $(seq 1 100); do
    if port_answers "$PORT" && owns_port "$SRV" "$PORT"; then ready=yes; break; fi
    if ! kill -0 "$SRV" 2>/dev/null; then break; fi
    sleep 0.2
done
if [ "$ready" != yes ]; then
    if port_answers "$PORT"; then
        echo "port $PORT is answering, but the listener is not in our process group: a concurrent" >&2
        echo "run took the port while we were starting. Re-run with a free PORT." >&2
    else
        echo "server never became ready on port $PORT; last log:" >&2
        tail -5 "$PROFILE/srv.log" >&2
    fi
    exit 1
fi

# Poll the check's own completion predicate ($2), then dump: replaces chrome --virtual-time-budget,
# which raced hydration under load and snapshot an empty DOM. Timeout dumps partial + exits 1 (a
# broken build still fails). render.mjs stderr is logged, never mixed into the captured DOM.
render() {
    node render.mjs --url "$1" --wait "$2" --timeout "${3:-30000}" 2>>"$PROFILE/render.err"
}

# The two adversarial stream URLs. Each drives one hostile body through the real render pipeline via
# a custom /dev/stream URL: no fixtures.zig edit, and the sanitizer/highlighter see attacker bytes.
read -r SAN_URL MD_URL < <(python3 - "$PORT" <<'PY'
import sys, urllib.parse
port = sys.argv[1]
png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
san = ('<img src="data:image/png;base64,' + png + '" onerror="alert(1)"> '
       '<img src="data:image/svg+xml;base64,AAAA"> '
       '<a href="javascript:alert(1)">js</a> '
       '<a href="https://ziglang.org">real</a> '
       '<span class="danger">card</span> '
       'She said "hello there" and `"code quote"` stays put.')
md = ('# Heading one\n\n'
      '| Col A | Col B |\n| --- | --- |\n| one | two |\n\n'
      '- [x] a done task\n- [ ] an open task\n\n'
      'She said "hello there", and inline `"code quote"` stays put.\n\n'
      '```js\nconst greeting = "not a quote";\nfunction f(x) { return x + 1; }\n```\n\n'
      '```python\ndef greet(name):\n    return "hi " + name\n```\n')
def top(inner_query):
    stream = "/dev/stream?" + inner_query
    return "http://127.0.0.1:%s/?demo=1&hold=6000&stream=%s" % (port, urllib.parse.quote(stream, safe=""))
# One token carries every sanitize vector; two tokens for the markdown body so the first code fence
# is not the streaming tail and actually gets highlighted.
print(top("n=1&prefix=" + urllib.parse.quote(san, safe="")),
      top("n=2&prefix=" + urllib.parse.quote(md, safe="")))
PY
)

echo
echo "== rendered dom (default) =="
# Completion: the client adds .hydrated to #chat-root once the SSR frames hold real bodies (main.js
# boot), and all twelve fixtures are in the log.
render "http://127.0.0.1:$PORT/?demo=1" \
    "document.querySelector('#chat-root.hydrated') && document.querySelectorAll('#chat .mes').length>=12" > "$DOM"
check "ssr placeholder replaced" "$(count 'ST_SSR_PLACEHOLDER' "$DOM")" 0
check "messages rendered" "$(count 'class="mes"' "$DOM")" 12
check "shell region present" "$(count 'id="shell"' "$DOM")" 1
check "messagelog region present" "$(count 'id="chat"' "$DOM")" 1
check "composer region present" "$(count 'id="composer"' "$DOM")" 1
# `<q` counts both quote forms, bare `<q>` and `<q class="q-turn">` (a broken-out speech turn); it
# never matches the `</q>` close.
check   "quotes open and close balance" "$(count '<q' "$DOM")" "$(count '</q>' "$DOM")"
check   "quotes wrapped" "$(count '<q' "$DOM")" 26
atleast "blockquotes" "$(count '<blockquote>' "$DOM")" 1
atleast "hard line breaks" "$(count '<br' "$DOM")" 1
atleast "emphasis" "$(count '<em>' "$DOM")" 1

echo
echo "== sanitize boundary (hostile body driven through the render) =="
# Completion: #probe-metrics is empty until the stream seals (main.js fills it in stream end), and the
# one streamed hostile body makes the thirteenth message.
render "$SAN_URL" \
    "JSON.parse(document.querySelector('#probe-metrics').textContent) && document.querySelectorAll('#chat .mes').length>=13" > "$SAN_DOM"
# The hostile message must have rendered at all: three fixtures plus the streamed one. If the body
# were dropped, the strip checks below would pass vacuously, so this is the anti-vacuous guard.
check   "hostile message rendered" "$(count 'class="mes"' "$SAN_DOM")" 13
check   "onerror attribute stripped" "$(count 'onerror=' "$SAN_DOM")" 0
check   "javascript: href stripped" "$(count 'href="javascript:' "$SAN_DOM")" 0
check   "svg data uri stripped" "$(count 'src="data:image/svg' "$SAN_DOM")" 0
atleast "png data uri preserved" "$(count 'src="data:image/png' "$SAN_DOM")" 1
atleast "author class namespaced to custom-" "$(count 'class="custom-danger"' "$SAN_DOM")" 1
atleast "rel=noopener forced on links" "$(count 'rel="noopener[^"]*"' "$SAN_DOM")" 1
atleast "real link href preserved" "$(count 'href="https://ziglang.org"' "$SAN_DOM")" 1

echo
echo "== markdown and highlighting (markdown body driven through the render) =="
# Same seal signal as the sanitize check: the two-token markdown body streams into the thirteenth message.
render "$MD_URL" \
    "JSON.parse(document.querySelector('#probe-metrics').textContent) && document.querySelectorAll('#chat .mes').length>=13" > "$MD_DOM"
atleast "headings" "$(count '<h1>' "$MD_DOM")" 1
atleast "tables" "$(count '<table>' "$MD_DOM")" 1
atleast "task list items" "$(count 'task-list-item' "$MD_DOM")" 2
atleast "hljs token spans" "$(count 'class="hljs-' "$MD_DOM")" 10
check   "hljs classes not namespaced" "$(count 'custom-hljs' "$MD_DOM")" 0
check   "language classes not namespaced" "$(count 'custom-language-' "$MD_DOM")" 0
python3 - "$MD_DOM" "$TALLY" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
leak = any("<q" in m.group(1) for m in re.finditer(r"<(?:code|pre)[^>]*>(.*?)</(?:code|pre)>", h, re.S))
print(f"  {'FAIL ' if leak else 'ok   '} {'q inside code or pre':<52} {'LEAK' if leak else 'none'}")
open(sys.argv[2], "w").write(f"1 {0 if leak else 1}")
sys.exit(1 if leak else 0)
PY
tally "markdown code-fence stage" $?

echo
echo "== dev endpoints are opt-in =="
refuse_taken_port $((PORT + 1)) "the no-dev server"
setsid timeout -k 5 20 python3 devserve.py --port $((PORT + 1)) --dist dist >/dev/null 2>&1 &
NODEV=$!
nodev_ready=no
for _ in $(seq 1 50); do
    if port_answers $((PORT + 1)) && owns_port "$NODEV" $((PORT + 1)); then nodev_ready=yes; break; fi
    if ! kill -0 "$NODEV" 2>/dev/null; then break; fi
    sleep 0.2
done
# This row is the one that a stranger's server would quietly pass: a --dev server on the same port
# answers /dev/stream with a 200 and the check reads as a dev-endpoint leak, or the reverse.
if [ "$nodev_ready" = yes ]; then
    code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$((PORT + 1))/dev/stream" 2>/dev/null)
    check "/dev/stream 404 without --dev" "$code" "404"
else
    echo "  FAIL  no-dev server never became ready"; FAILURES=$((FAILURES + 1))
fi
kill -TERM -- -"$NODEV" 2>/dev/null

echo
echo "== streaming and the render cache =="
# Completion: the 200-token stream has sealed and written its final metrics.
render "http://127.0.0.1:$PORT/?demo=1&stream=1&hold=6000" \
    "JSON.parse(document.querySelector('#probe-metrics').textContent).tokens===200" > "$STREAM_DOM"
python3 - "$STREAM_DOM" "$TALLY" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'<pre id="probe-metrics"[^>]*>(.*?)</pre>', h, re.S)
if not m:
    print("  FAIL  no probe-metrics block")
    open(sys.argv[2], "w").write("1 0")
    sys.exit(1)
s = json.loads(m.group(1))
fail = 0
rows = 0

def check(label, ok, detail):
    global fail, rows
    rows += 1
    print(f"  {'ok   ' if ok else 'FAIL '} {label:<52} {detail}")
    if not ok:
        fail += 1

check("all tokens delivered", s["tokens"] == 200, s["tokens"])
check("writes coalesced per frame", s["flushes"] < 60, f"{s['flushes']} flushes for 200 tokens")
# The twelve example fixtures sanitize at boot, then one per flush for the uncached streaming tail.
budget = 12 + s["flushes"] + 2
check("render cache holds", s["sanitizes"] <= budget, f"{s['sanitizes']} sanitizes, budget {budget}")
check("tail text present", "tok199" in h, "tok199")
check("streamed message appended", len(re.findall(r'class="mes"', h)) == 13, len(re.findall(r'class="mes"', h)))
open(sys.argv[2], "w").write(f"{rows} {rows - fail}")
sys.exit(1 if fail else 0)
PY
tally "streaming and render-cache stage" $?

echo
echo "== two consecutive streams keep separate bodies =="
# Completion: the SECOND stream ran to its last token (bbb19). The first stream fills #probe-metrics
# before the second even begins, so gate on the second stream's tail, not on the metrics block.
render "http://127.0.0.1:$PORT/?demo=1&stream=2&hold=5000" \
    "document.body.textContent.includes('bbb19')" > "$STREAM_DOM"
python3 - "$STREAM_DOM" "$TALLY" <<'PY2'
import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# The reasoning block (w3-reason) always sits between mes_name and mes_text; skip it. mes_text may
# carry mes-justify, and missing that here lets the skip group backtrack across whole messages.
msgs = re.findall(r'<div class="mes_name">([^<]*)</div>(?:<div class="mes_reasoning.*?</div></div>)?<div class="mes_text[^"]*"[^>]*>(.*?)</div>', h, re.S)
want = {"First": (True, False), "Second": (False, True)}
seen = set()
fail = 0
for name, body in msgs:
    if name not in want:
        continue
    seen.add(name)
    txt = re.sub(r"<[^>]+>", "", body)
    got = ("aaa0" in txt, "bbb0" in txt)
    ok = got == want[name]
    print(f"  {'ok   ' if ok else 'FAIL '} {name + ' message owns its tokens':<52} aaa={got[0]} bbb={got[1]}")
    if not ok:
        fail += 1
for name in want:
    if name not in seen:
        print(f"  FAIL  {name + ' streamed message not found':<52}")
        fail += 1
# Both names are always owed a verdict, so the denominator is the two we wanted, never the ones we
# happened to find: a run that renders neither message must read 0 of 2, not 0 of 0.
open(sys.argv[2], "w").write(f"{len(want)} {len(want) - fail}")
sys.exit(1 if fail else 0)
PY2
tally "two-consecutive-streams stage" $?

echo
echo "== mobile layout (390x844) + desktop console guard =="
# --- mobile ---
# mobile-audit.mjs drives its own headless Chrome against the server already on $PORT and checks the
# phone-layout invariants a desktop render cannot see: every panel fills the width and scrolls, the
# topbar taps are reachable, no real console error or missing dist asset. A backend-route 404 is
# reported, not failed (this static gate has no Express backend). Second run guards the desktop console.
MOBILE_JSON=$(mktemp)
DESKTOP_JSON=$(mktemp)
node mobile-audit.mjs --url "http://127.0.0.1:$PORT/?demo=1" --mode mobile  2>>"$PROFILE/render.err" > "$MOBILE_JSON"
node mobile-audit.mjs --url "http://127.0.0.1:$PORT/?demo=1" --mode desktop 2>>"$PROFILE/render.err" > "$DESKTOP_JSON"
python3 - "$MOBILE_JSON" "$DESKTOP_JSON" "$TALLY" <<'PY'
import json, sys
def load(p):
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception as e:
        return {"__load_error": str(e)}
mob = load(sys.argv[1]); desk = load(sys.argv[2])
fail = 0
rows = 0
def tally():
    open(sys.argv[3], "w").write(f"{rows} {rows - fail}")
def check(label, ok, detail=""):
    global fail, rows
    rows += 1
    print(f"  {'ok   ' if ok else 'FAIL '} {label:<52} {detail}")
    if not ok:
        fail += 1
def has(rep, *ids):
    return any(v.get("id") in ids for v in rep.get("violations", []))
if "__load_error" in mob:
    check("mobile audit ran", False, mob["__load_error"])
    tally()
    sys.exit(1)
panels = mob.get("panels", [])
tb = mob.get("topbar", {})
check("mobile: no horizontal overflow", not mob.get("overflowX", True))
# The 13-button top bar is gone: the two edge tabs are the launchers, and on touch they never hide.
check("mobile: 2 edge tabs >=44px reachable", tb.get("count") == 2 and not has(mob, "topbar-count", "topbar-tap", "topbar-reachable"))
check("mobile: 2 panels open >=80% wide in view", len(panels) == 2 and all(p.get("open") for p in panels) and not has(mob, "panel-open", "panel-width", "panel-inviewport"), f"{len(panels)} panels")
check("mobile: panels scrollable on overflow", not has(mob, "panel-scroll"))
check("mobile: reachability sweep 0 clipped", not has(mob, "panel-reachable"), f"{sum(p.get('clippedControls', 0) for p in panels)} clipped")
check("mobile: 0 console errors", not has(mob, "console-errors"), f"{len(mob.get('consoleErrors', []))} err")
check("mobile: 0 missing dist assets", not has(mob, "missing-asset"), f"{len(mob.get('missingAssets', []))} missing, {len(mob.get('harnessBackend404', []))} backend-404 exempt")
if "__load_error" in desk:
    check("desktop audit ran", False, desk["__load_error"])
else:
    check("desktop: 0 console errors, no overflow", not desk.get("violations"), f"{len(desk.get('consoleErrors', []))} err")
tally()
sys.exit(1 if fail else 0)
PY
tally "mobile and desktop audit stage" $?
rm -f "$MOBILE_JSON" "$DESKTOP_JSON"
echo

echo "== reader history paging (mock 300-message chat) =="
# Mock 300-message chat: open lands at the bottom, then scroll to the top and prove the prepend keeps
# every existing .mes and holds the anchor within 2px (element-anchored correction, not scrollHeight-delta).
HIST_PORT=$((PORT + 2))
refuse_taken_port "$HIST_PORT" "the reader-history server"
setsid timeout -k 5 90 python3 devserve.py --port "$HIST_PORT" --dist dist --mock-api >"$PROFILE/hist.log" 2>&1 &
HISTSRV=$!
hist_ready=no
for _ in $(seq 1 100); do
    if port_answers "$HIST_PORT" && owns_port "$HISTSRV" "$HIST_PORT"; then hist_ready=yes; break; fi
    if ! kill -0 "$HISTSRV" 2>/dev/null; then break; fi
    sleep 0.2
done
if [ "$hist_ready" != yes ]; then
    # Its four rows did not run. Say four, not one: a stage that cannot start is the exact case a
    # denominator exists to expose.
    echo "  FAIL  reader history server never became ready"
    printf '4 0' > "$TALLY"
    tally "reader history paging stage" 1
else
    node history-gate.mjs "http://127.0.0.1:$HIST_PORT/" >"$HIST_JSON" 2>>"$PROFILE/render.err"
    python3 - "$HIST_JSON" "$TALLY" <<'PY'
import json, sys
# The four rows are owed whether or not the driver produced JSON, so a crashed driver reads 0 of 4
# rather than shrinking the denominator to nothing and calling the stage one failure.
OWED = 4
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"  FAIL  history-gate produced no JSON ({e})")
    open(sys.argv[2], "w").write(f"{OWED} 0")
    sys.exit(1)
post = d.get("post", {})
fail = 0
rows = 0
def check(label, ok, detail):
    global fail, rows
    rows += 1
    print(f"  {'ok   ' if ok else 'FAIL '} {label:<52} {detail}")
    if not ok:
        fail += 1
check("open lands at the bottom", d.get("openAtBottom") is True, d.get("openAtBottom"))
check("a scroll-up prepend landed", post.get("finalCount", 0) > post.get("tagged", 0), f"{post.get('tagged')} -> {post.get('finalCount')}")
check("every existing message survived the prepend", post.get("survived") == post.get("tagged"), f"{post.get('survived')} of {post.get('tagged')}")
check("reading anchor held within 2px", isinstance(post.get("anchorDrift"), (int, float)) and post["anchorDrift"] < 2.0, f"{post.get('anchorDrift')}px")
assert rows == OWED, f"history stage wrote {rows} rows but owes {OWED}"
open(sys.argv[2], "w").write(f"{rows} {rows - fail}")
sys.exit(1 if fail else 0)
PY
    tally "reader history paging stage" $?
fi
kill -TERM -- -"$HISTSRV" 2>/dev/null
HISTSRV=""

echo
echo "== api routes (every path the client calls exists on the real server) =="
# Static, no browser and no mock: the mock is exactly what this cannot ask, since a mock that invents
# a route makes the gate green while the user gets a 404.
if node check-api-routes.mjs; then
    check "api routes" pass pass
else
    check "api routes" fail pass
fi

echo
echo "== interactions (real input against the served client) =="
# Self-contained stage: verify-interactions.sh starts its own mock-api server on its own port.
# One row, and it is a row about a runner, not about the client: interactions.mjs prints its own
# count of its own rows and only an exit code reaches here. Reading its 221 rows into this total
# would mean parsing its output, which is a claim about text rather than about counters.
if [ "${INTERACTIONS:-1}" = "1" ]; then
    if ./verify-interactions.sh; then
        check "interaction gate (rows counted in its own summary)" pass pass
    else
        check "interaction gate (rows counted in its own summary)" fail pass
    fi
else
    echo "  skip  interaction gate (INTERACTIONS=0)"
fi

echo
# The verdict carries its denominator. ROWS and PASSES are incremented by the same helpers that
# decide each row, so a stage that never ran cannot inflate the total, and a total that drops between
# runs is itself the finding: rows disappeared rather than failed.
if [ "$ROWS" -ne $((PASSES + FAILURES)) ]; then
    echo "verify.sh: BUG, $ROWS rows but $PASSES passed + $FAILURES failed do not account for them"
    exit 1
fi
printf 'verify.sh: %s of %s rows passed, %s failed\n' "$PASSES" "$ROWS" "$FAILURES"
# `exit "$FAILURES"` would wrap mod 256, so 256 failures would report success. Cap at 1.
[ "$FAILURES" -eq 0 ] && exit 0 || exit 1
