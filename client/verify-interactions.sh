#!/usr/bin/env bash
# Interaction gate: serve dist with the canned mock API and drive real clicks/keys/drags through
# interactions.mjs. Self-contained; verify.sh calls it as its last stage (INTERACTIONS=0 skips).
set -uo pipefail

cd "$(dirname "$0")"

PORT="${IPORT:-8907}"
PROFILE=$(mktemp -d)
SRV=""
cleanup() {
    [ -n "$SRV" ] && kill -TERM -- -"$SRV" 2>/dev/null
    rm -rf "$PROFILE"
}
trap cleanup EXIT

[ -f dist/index.html ] || { echo "no dist/index.html: run ./build.sh first" >&2; exit 1; }
command -v google-chrome-stable >/dev/null 2>&1 || { echo "google-chrome-stable not on PATH" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node not on PATH" >&2; exit 1; }
node -e 'process.exit(typeof WebSocket==="function"&&typeof fetch==="function"?0:1)' 2>/dev/null || {
    echo "node lacks global WebSocket/fetch (need >=22; project pins >=26)" >&2; exit 1
}

setsid timeout 300 python3 devserve.py --port "$PORT" --dist dist --dev --mock-api >"$PROFILE/srv.log" 2>&1 &
SRV=$!
ready=no
for _ in $(seq 1 100); do
    if curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then ready=yes; break; fi
    if ! kill -0 "$SRV" 2>/dev/null; then break; fi
    sleep 0.2
done
if [ "$ready" != yes ]; then
    echo "mock server never became ready on port $PORT; last log:" >&2
    tail -5 "$PROFILE/srv.log" >&2
    exit 1
fi

node interactions.mjs --base "http://127.0.0.1:$PORT"
