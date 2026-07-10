#!/usr/bin/env bash
# End-to-end gate. Covers what `zig build test` cannot: hydration, the sanitize boundary, the
# render cache, and streaming, all against a real browser.
#
# Usage: ./verify.sh   (expects `zig build -Doptimize=ReleaseSmall && zig build export` already run)
set -uo pipefail

cd "$(dirname "$0")"

PORT="${PORT:-8899}"
FAILURES=0
DOM=$(mktemp)
STREAM_DOM=$(mktemp)
PROFILE=$(mktemp -d)
trap 'rm -rf "$DOM" "$STREAM_DOM" "$PROFILE"; [ -n "${SRV:-}" ] && kill -TERM "$SRV" 2>/dev/null' EXIT

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

DOOR="dist/vendor/ziex/wasm/index.js"

[ -f dist/index.html ] || { echo "no dist/: run 'zig build export' first" >&2; exit 1; }
[ -f "$DOOR" ] || { echo "no $DOOR: run 'zig build export' first" >&2; exit 1; }

# Budget: two sleeps plus three chrome loads capped at 60s each, so the server must outlive 182s.
setsid timeout 300 python3 devserve.py --port "$PORT" --dist dist --dev >/dev/null 2>&1 &
SRV=$!
sleep 2

chrome() {
    timeout 60 google-chrome-stable --headless --disable-gpu --no-sandbox \
        --user-data-dir="$PROFILE" --dump-dom --virtual-time-budget="$2" "$1" 2>/dev/null
}

count() { grep -o "$1" "$2" 2>/dev/null | wc -l; }

echo "== build artifacts =="
check "door patched, no stringCache" "$(count 'stringCache' "$DOOR")" 0

echo
echo "== served html (pre-hydration) =="
check "hydration markers in index.html" "$(count '<!--\$' dist/index.html)" 1
check "ssr placeholder, one per message" "$(count 'ST_SSR_PLACEHOLDER' dist/index.html)" 7

echo
echo "== rendered dom =="
chrome "http://127.0.0.1:$PORT/" 9000 > "$DOM"
check "ssr placeholder replaced" "$(count 'ST_SSR_PLACEHOLDER' "$DOM")" 0
check "messages rendered" "$(count 'class="mes"' "$DOM")" 7
check "demo sections" "$(count 'class="demo"' "$DOM")" 4

echo
echo "== sanitize boundary =="
check "onerror attribute stripped" "$(count 'onerror=' "$DOM")" 0
check "javascript: href stripped" "$(count 'href="javascript:' "$DOM")" 0
check "svg data uri stripped" "$(count 'src="data:image/svg' "$DOM")" 0
check "png data uri preserved" "$(count 'src="data:image/png' "$DOM")" 1
check "author class namespaced" "$(count 'class="custom-danger"' "$DOM")" 1
atleast "rel=noopener forced on links" "$(count 'rel="noopener"' "$DOM")" 2

echo
echo "== markdown =="
atleast "headings" "$(count '<h1>' "$DOM")" 1
atleast "blockquotes" "$(count '<blockquote>' "$DOM")" 2
atleast "tables" "$(count '<table>' "$DOM")" 1
atleast "hard line breaks" "$(count '<br' "$DOM")" 3
atleast "task list items" "$(count 'task-list-item' "$DOM")" 2

echo
echo "== quote colouring =="
check "q opens and closes balance" "$(count '<q>' "$DOM")" "$(count '</q>' "$DOM")"
atleast "quotes wrapped" "$(count '<q>' "$DOM")" 11
python3 - "$DOM" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
leak = any("<q>" in m.group(1) for m in re.finditer(r"<(?:code|pre)[^>]*>(.*?)</(?:code|pre)>", h, re.S))
print(f"  {'FAIL ' if leak else 'ok   '} {'q inside code or pre':<52} {'LEAK' if leak else 'none'}")
sys.exit(1 if leak else 0)
PY
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

echo
echo "== highlighting =="
atleast "hljs token spans" "$(count 'class="hljs-' "$DOM")" 10
check "no namespaced hljs classes" "$(count 'custom-hljs' "$DOM")" 0

echo
echo "== dev endpoints are opt-in =="
setsid timeout 20 python3 devserve.py --port $((PORT + 1)) --dist dist >/dev/null 2>&1 &
NODEV=$!
sleep 2
code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$((PORT + 1))/dev/stream" 2>/dev/null)
kill -TERM "$NODEV" 2>/dev/null
check "/dev/stream 404 without --dev" "$code" "404"

echo
echo "== streaming and the render cache =="
chrome "http://127.0.0.1:$PORT/?stream=1&hold=6000" 30000 > "$STREAM_DOM"
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
# 7 fixtures at boot + 1 at stream start + one per frame for the uncached tail.
budget = 8 + s["flushes"] + 2
check("render cache holds", s["sanitizes"] <= budget, f"{s['sanitizes']} sanitizes, budget {budget}")
check("tail text present", "tok199" in h, "tok199")
check("streamed message appended", len(re.findall(r'class="mes"', h)) == 8, len(re.findall(r'class="mes"', h)))
sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

echo
echo "== two consecutive streams keep separate bodies =="
chrome "http://127.0.0.1:$PORT/?stream=2&hold=5000" 20000 > "$STREAM_DOM"
python3 - "$STREAM_DOM" <<'PY2'
import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
msgs = re.findall(r'<div class="mes_name">([^<]*)</div><div class="mes_text"[^>]*>(.*?)</div>', h, re.S)
want = {"First": (True, False), "Second": (False, True)}
fail = 0
for name, body in msgs:
    if name not in want:
        continue
    txt = re.sub(r"<[^>]+>", "", body)
    got = ("aaa0" in txt, "bbb0" in txt)
    ok = got == want[name]
    print(f"  {'ok   ' if ok else 'FAIL '} {name + ' message owns its tokens':<52} aaa={got[0]} bbb={got[1]}")
    if not ok:
        fail += 1
if len(msgs) < 2:
    print("  FAIL  two streamed messages not found")
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
exit "$FAILURES"
