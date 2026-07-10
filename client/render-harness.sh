#!/usr/bin/env bash
# Render-count regression harness for the memoization refactor: builds an instrumented wasm
# (-Dinstrument), drives a fixed token stream one token per feed headless, reports the per-token
# MessageView render count. Baseline pre-memo = on-screen message count/token; post-memo it drops
# to 1. Deterministic drive in renderCountProbe (glue/main.js). Rebuilds the production dist at end.
#
# Usage: ./render-harness.sh        (env: OPT, PORT, TOKENS, MSGS)
set -uo pipefail

cd "$(dirname "$0")"

OPT="${OPT:-ReleaseSmall}"
PORT="${PORT:-8901}"
TOKENS="${TOKENS:-60}"
MSGS="${MSGS:-4}"

DOM=$(mktemp)
PROFILE=$(mktemp -d)
FAILURES=0
trap 'rm -rf "$DOM" "$PROFILE"; [ -n "${SRV:-}" ] && kill -TERM "$SRV" 2>/dev/null' EXIT

echo "== build (instrumented) =="
# The export CLI recompiles the wasm through an inner `zig build`, so -Dinstrument must ride in on
# the CLI's --build-args, not the outer command. The wasm stays ReleaseSmall (inner default).
./setup-ziex.sh >/dev/null
zig build export "-Doptimize=$OPT" -- --build-args=-Dinstrument
./patch-door.sh >/dev/null

WASM=$(find dist -name '*.wasm' | head -1)
[ -n "$WASM" ] || { echo "render-harness: no wasm in dist; export failed" >&2; exit 1; }
if ! grep -aq '__st_mv_renders' "$WASM"; then
    echo "render-harness: __st_mv_renders export missing from wasm; instrumentation not compiled" >&2
    exit 1
fi

echo
echo "== drive the render-count probe =="
setsid timeout 120 python3 devserve.py --port "$PORT" --dist dist >/dev/null 2>&1 &
SRV=$!
sleep 2

timeout 60 google-chrome-stable --headless --disable-gpu --no-sandbox \
    --user-data-dir="$PROFILE" --dump-dom --virtual-time-budget=20000 \
    "http://127.0.0.1:$PORT/?rendercount=1&msgs=$MSGS&tokens=$TOKENS" 2>/dev/null > "$DOM"

BASELINE=$(python3 - "$DOM" "$TOKENS" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
want_tokens = int(sys.argv[2])
m = re.search(r'<pre id="probe-metrics"[^>]*>(.*?)</pre>', h, re.S)
if not m:
    print("  FAIL  no probe-metrics block (wasm boot or probe failed)", file=sys.stderr)
    sys.exit(2)
s = json.loads(m.group(1))
fail = 0

def check(label, ok, detail):
    global fail
    print(f"  {'ok   ' if ok else 'FAIL '} {label:<48} {detail}", file=sys.stderr)
    if not ok:
        fail += 1

n = s["onscreen"]
check("stream delivered every token", s["streamTokens"] == want_tokens,
      f"{s['streamTokens']} of {want_tokens}")
check("render count constant across tokens", s["constant"],
      f"min {s['perTokenMin']}, max {s['perTokenMax']}")
check("per-token count == on-screen messages", s["perTokenMax"] == n and s["perTokenMin"] == n,
      f"{s['perTokenMax']} renders/token, {n} on screen")
check("on-screen count above 1 (baseline is meaningful)", n > 1, f"{n} messages")
print(f"  baseline: {n} MessageView renders per token over {n} on-screen messages "
      f"({want_tokens} tokens, {s['perTokenSum']} total)", file=sys.stderr)
# stdout carries only the baseline number for the caller.
print(n)
sys.exit(1 if fail else 0)
PY
)
PARSE=$?
[ "$PARSE" -eq 0 ] || FAILURES=$((FAILURES + 1))

kill -TERM "$SRV" 2>/dev/null
SRV=""

echo
echo "== restore production dist (no instrumentation) =="
zig build export "-Doptimize=$OPT" >/dev/null
./patch-door.sh >/dev/null
PROD_WASM=$(find dist -name '*.wasm' | head -1)
if grep -aq '__st_mv_renders' "$PROD_WASM"; then
    echo "  FAIL  __st_mv_renders still present in production wasm" >&2
    FAILURES=$((FAILURES + 1))
else
    echo "  ok    production wasm carries no render counter"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "render-harness: baseline = $BASELINE MessageView renders per token (pre-memoization)"
else
    echo "render-harness: $FAILURES check(s) failed"
fi
exit "$FAILURES"
