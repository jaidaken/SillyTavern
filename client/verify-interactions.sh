#!/usr/bin/env bash
# Interaction gate: serve dist with the canned mock API and drive real clicks/keys/drags through
# interactions.mjs. Self-contained; verify.sh calls it as its last stage (INTERACTIONS=0 skips).
set -uo pipefail

cd "$(dirname "$0")"

PORT="${IPORT:-8907}"
PROFILE=$(mktemp -d)
SRV=""
cleanup() {
    if [ -n "$SRV" ]; then
        kill -TERM -- -"$SRV" 2>/dev/null
        # SIGTERM alone has left servers alive holding this port: the graceful path can park the main
        # thread in an untimed futex, and then nothing here escalates. Give it a moment, then insist.
        for _ in 1 2 3 4 5 6 7 8; do
            kill -0 -- -"$SRV" 2>/dev/null || break
            sleep 0.25
        done
        kill -KILL -- -"$SRV" 2>/dev/null
    fi
    rm -rf "$PROFILE"
}
trap cleanup EXIT

[ -f dist/index.html ] || { echo "no dist/index.html: run ./build.sh first" >&2; exit 1; }
command -v google-chrome-stable >/dev/null 2>&1 || { echo "google-chrome-stable not on PATH" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node not on PATH" >&2; exit 1; }
node -e 'process.exit(typeof WebSocket==="function"&&typeof fetch==="function"?0:1)' 2>/dev/null || {
    echo "node lacks global WebSocket/fetch (need >=22; project pins >=26)" >&2; exit 1
}

# -k 5 is load-bearing, not decoration: the three launches in verify.sh have it and this one did not,
# so every orphan found so far has been THIS server. Without the SIGKILL escalation a timeout that
# fires on a parked process leaves it holding this port forever, serving a STALE dist to later runs.
setsid timeout -k 5 300 python3 devserve.py --port "$PORT" --dist dist --dev --mock-api >"$PROFILE/srv.log" 2>&1 &
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
