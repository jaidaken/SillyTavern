#!/usr/bin/env bash
# SSH-forward a local port to .43's localhost:8000 (which ST whitelists), so dev reaches ST without
# opening its edge-only firewall. Needs .43 unlocked via silly.jaidaken.dev, else requests 502.
set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8143}"

echo "dev-tunnel: forwarding 127.0.0.1:${LOCAL_PORT} -> silly(.43) ST 127.0.0.1:8000 over ssh"
echo "dev-tunnel: point the dev server at --backend http://127.0.0.1:${LOCAL_PORT}"
exec ssh -N -L "${LOCAL_PORT}:127.0.0.1:8000" silly
