#!/usr/bin/env bash
# Full patched build: materialize patched ziex, compile, export, patch the door. Use this, not
# bare `zig build`, so the four ziex patches (three source + the door) are all in effect.
set -euo pipefail

cd "$(dirname "$0")"

OPT="${OPT:-ReleaseSmall}"

# Always run: setup-ziex is idempotent, and a reused .ziex may be unpinned or unpatched.
./setup-ziex.sh
zig build "-Doptimize=$OPT"
zig build export "-Doptimize=$OPT"
./patch-door.sh

echo "build.sh: done (opt=$OPT). Run ./verify.sh for the browser gate."
