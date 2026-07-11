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
DOM=$(mktemp)
SAN_DOM=$(mktemp)
MD_DOM=$(mktemp)
STREAM_DOM=$(mktemp)
PROFILE=$(mktemp -d)
SRV=""
NODEV=""
cleanup() {
    # setsid makes each server its own process-group leader, so a group kill reaps the timeout
    # wrapper, python, and its handler threads together; a bare kill would orphan them.
    [ -n "$SRV" ] && kill -TERM -- -"$SRV" 2>/dev/null
    [ -n "$NODEV" ] && kill -TERM -- -"$NODEV" 2>/dev/null
    rm -rf "$DOM" "$SAN_DOM" "$MD_DOM" "$STREAM_DOM" "$PROFILE"
}
trap cleanup EXIT

check() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        printf '  ok    %-52s %s\n' "$label" "$actual"
    else
        printf '  FAIL  %-52s got %s, want %s\n' "$label" "$actual" "$expected"
        FAILURES=$((FAILURES + 1))
    fi
}

atleast() {
    local label="$1" actual="$2" floor="$3"
    if [ "$actual" -ge "$floor" ]; then
        printf '  ok    %-52s %s (>= %s)\n' "$label" "$actual" "$floor"
    else
        printf '  FAIL  %-52s got %s, want >= %s\n' "$label" "$actual" "$floor"
        FAILURES=$((FAILURES + 1))
    fi
}

count() { grep -o "$1" "$2" 2>/dev/null | wc -l; }

DOOR="dist/vendor/ziex/wasm/index.js"
WASM="dist/assets/_/main.wasm"

# Preflight. A missing artifact must name itself, not surface later as a browser check that reads
# exactly like a real regression (empty DOM, everything zero).
[ -f dist/index.html ] || { echo "no dist/index.html: run ./build.sh first" >&2; exit 1; }
[ -f "$DOOR" ] || { echo "no $DOOR: run ./build.sh first" >&2; exit 1; }
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

echo "== zig gates =="
if zig build check; then echo "  ok    zig fmt --check"; else echo "  FAIL  zig fmt --check"; FAILURES=$((FAILURES + 1)); fi
if zig build test;  then echo "  ok    zig build test";  else echo "  FAIL  zig build test";  FAILURES=$((FAILURES + 1)); fi

echo
echo "== build artifacts =="
# Patched state is the PRESENCE of the uncached readString body, never the absence of a cache
# marker: a reformatted door has both cache markers absent while still carrying the D1 stale read.
door_uncached=$(grep -Fc 'return textDecoder.decode(getMemoryView().subarray(ptr, ptr + len));' "$DOOR")
atleast "door patched: uncached readString body" "$door_uncached" 1
check   "main.wasm present" "$([ -f "$WASM" ] && echo yes || echo no)" "yes"

echo
echo "== served html (pre-hydration) =="
# Three client regions (Shell, MessageLog, Composer), each with one SSR marker; three fixtures, each
# body a placeholder the client replaces.
check "region hydration markers in index.html" "$(count '<!--\$' dist/index.html)" 3
check "ssr placeholder, one per message" "$(count 'ST_SSR_PLACEHOLDER' dist/index.html)" 12

# Start the server for every browser check. --dev exposes /dev/stream and /dev/hold. setsid so the
# whole tree dies with the group kill in cleanup.
setsid timeout 320 python3 devserve.py --port "$PORT" --dist dist --dev >"$PROFILE/srv.log" 2>&1 &
SRV=$!
# Poll readiness rather than sleep: a loaded box or an already-bound port must fail loudly, not race.
ready=no
for _ in $(seq 1 100); do
    if curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then ready=yes; break; fi
    if ! kill -0 "$SRV" 2>/dev/null; then break; fi
    sleep 0.2
done
if [ "$ready" != yes ]; then
    echo "server never became ready on port $PORT; last log:" >&2
    tail -5 "$PROFILE/srv.log" >&2
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
    return "http://127.0.0.1:%s/?hold=6000&stream=%s" % (port, urllib.parse.quote(stream, safe=""))
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
render "http://127.0.0.1:$PORT/" \
    "document.querySelector('#chat-root.hydrated') && document.querySelectorAll('#chat .mes').length>=12" > "$DOM"
check "ssr placeholder replaced" "$(count 'ST_SSR_PLACEHOLDER' "$DOM")" 0
check "messages rendered" "$(count 'class="mes"' "$DOM")" 12
check "shell region present" "$(count 'id="shell"' "$DOM")" 1
check "messagelog region present" "$(count 'id="chat"' "$DOM")" 1
check "composer region present" "$(count 'id="composer"' "$DOM")" 1
# The three roleplay fixtures carry real quotes, a blockquote, emphasis, and a hard break.
check   "quotes open and close balance" "$(count '<q>' "$DOM")" "$(count '</q>' "$DOM")"
check   "quotes wrapped" "$(count '<q>' "$DOM")" 26
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
python3 - "$MD_DOM" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
leak = any("<q>" in m.group(1) for m in re.finditer(r"<(?:code|pre)[^>]*>(.*?)</(?:code|pre)>", h, re.S))
print(f"  {'FAIL ' if leak else 'ok   '} {'q inside code or pre':<52} {'LEAK' if leak else 'none'}")
sys.exit(1 if leak else 0)
PY
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

echo
echo "== dev endpoints are opt-in =="
setsid timeout 20 python3 devserve.py --port $((PORT + 1)) --dist dist >/dev/null 2>&1 &
NODEV=$!
nodev_ready=no
for _ in $(seq 1 50); do
    if curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$((PORT + 1))/" 2>/dev/null; then nodev_ready=yes; break; fi
    if ! kill -0 "$NODEV" 2>/dev/null; then break; fi
    sleep 0.2
done
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
render "http://127.0.0.1:$PORT/?stream=1&hold=6000" \
    "JSON.parse(document.querySelector('#probe-metrics').textContent).tokens===200" > "$STREAM_DOM"
python3 - "$STREAM_DOM" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'<pre id="probe-metrics"[^>]*>(.*?)</pre>', h, re.S)
if not m:
    print("  FAIL  no probe-metrics block")
    sys.exit(1)
s = json.loads(m.group(1))
fail = 0

def check(label, ok, detail):
    global fail
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
sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

echo
echo "== two consecutive streams keep separate bodies =="
# Completion: the SECOND stream ran to its last token (bbb19). The first stream fills #probe-metrics
# before the second even begins, so gate on the second stream's tail, not on the metrics block.
render "http://127.0.0.1:$PORT/?stream=2&hold=5000" \
    "document.body.textContent.includes('bbb19')" > "$STREAM_DOM"
python3 - "$STREAM_DOM" <<'PY2'
import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
msgs = re.findall(r'<div class="mes_name">([^<]*)</div><div class="mes_text"[^>]*>(.*?)</div>', h, re.S)
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
sys.exit(1 if fail else 0)
PY2
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "verify.sh: all checks passed"
else
    echo "verify.sh: $FAILURES check(s) failed"
fi
# `exit "$FAILURES"` would wrap mod 256, so 256 failures would report success. Cap at 1.
[ "$FAILURES" -eq 0 ] && exit 0 || exit 1