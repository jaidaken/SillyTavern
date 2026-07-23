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

# A curl answer proves A server is on this port, never that it is OURS: a stranger holding it answers
# our first poll, our python3 dies of EADDRINUSE unnoticed, and the rows drive the OTHER run's mock.
# The CONN rows then fail for a reason that has nothing to do with the code under test.
command -v ss >/dev/null 2>&1 || { echo "ss not on PATH: cannot prove we own port $PORT" >&2; exit 1; }

# setsid makes the launched wrapper its own group leader, so everything it spawns carries its pid as
# the PGID: the listener being in that group is proof the socket is ours.
owns_port() {
    local pgid="$1" port="$2" lpid
    lpid=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
    [ -n "$lpid" ] || return 1
    [ "$(ps -o pgid= -p "$lpid" 2>/dev/null | tr -d ' ')" = "$pgid" ]
}

if curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    echo "port $PORT already answers before we started: another run holds it." >&2
    echo "pass a unique IPORT (concurrent gates must not share one), or kill the stale server:" >&2
    echo "  ps -eo pid,cmd | grep '[d]evserve'   # NixOS has no fuser; never a broad pkill" >&2
    exit 1
fi

# ONE knob for both lifetimes. These drifted apart once and the suite grew past the server's cap, so
# the server was killed mid-run and every later row waited on a dead socket for minutes, reading as
# slow tests rather than a dead dependency. The server must always outlive the watchdog.
WATCHDOG_MS="${WATCHDOG_MS:-600000}"
SRV_SECONDS=$(( WATCHDOG_MS / 1000 + 60 ))

# -k 5 is load-bearing, not decoration: the three launches in verify.sh have it and this one did not,
# so every orphan found so far has been THIS server. Without the SIGKILL escalation a timeout that
# fires on a parked process leaves it holding this port forever, serving a STALE dist to later runs.
setsid timeout -k 5 "$SRV_SECONDS" python3 devserve.py --port "$PORT" --dist dist --dev --mock-api >"$PROFILE/srv.log" 2>&1 &
SRV=$!
ready=no
for _ in $(seq 1 100); do
    # Both halves: answering proves a server is up, owns_port proves it is the one we just launched.
    # A stranger binding DURING our startup still wins the pre-check race above; this catches it.
    if curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && owns_port "$SRV" "$PORT"; then
        ready=yes; break
    fi
    if ! kill -0 "$SRV" 2>/dev/null; then break; fi
    sleep 0.2
done
if [ "$ready" != yes ]; then
    echo "mock server never became ready on port $PORT (or the listener is not ours); last log:" >&2
    tail -5 "$PROFILE/srv.log" >&2
    exit 1
fi

node interactions.mjs --base "http://127.0.0.1:$PORT" --timeout "$WATCHDOG_MS"
