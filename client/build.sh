#!/usr/bin/env bash
# Full patched build: materialize patched ziex, compile, export, patch the door. Use this, not
# bare `zig build`, so the four ziex patches (three source + the door) are all in effect.
set -euo pipefail

cd "$(dirname "$0")"

OPT="${OPT:-ReleaseSmall}"

# Always run: setup-ziex is idempotent, and a reused .ziex may be unpinned or unpatched.
./setup-ziex.sh

# Quality gates before the artifact: unformatted source or a failing unit test must stop the build,
# not ship. Both need .ziex present because build.zig imports ziex.
zig build check
zig build test

zig build "-Doptimize=$OPT"
zig build export "-Doptimize=$OPT"
# Order is load-bearing: export writes dist, patch-door edits the door in place, prune trims the
# unpruned ziex npm tree export copied in. verify.sh then runs against the pruned artifact.
./patch-door.sh
./prune-dist.sh dist

echo "build.sh: done (opt=$OPT). Run ./verify.sh for the browser gate."
