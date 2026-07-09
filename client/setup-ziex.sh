#!/usr/bin/env bash
# Materialize patched ziex at client/.ziex (gitignored) from client/patches/; delete + rerun to rebuild.
# The door patch (D1) is in the prebuilt tarball, not source, so it is applied post-export in patch-door.sh.
set -euo pipefail

cd "$(dirname "$0")"

ZIEX_REV="26f594531d302421f4e53b52c9b3c653093c1392"
ZIEX_DIR=".ziex"
PATCHES="patches"

if [ -d "$ZIEX_DIR/.git" ]; then
    cur=$(git -C "$ZIEX_DIR" rev-parse HEAD 2>/dev/null || echo none)
    if [ "$cur" = "$ZIEX_REV" ] && git -C "$ZIEX_DIR" diff --quiet 2>/dev/null; then
        echo "setup-ziex: $ZIEX_DIR clean at $ZIEX_REV, reapplying patches"
    fi
fi

rm -rf "$ZIEX_DIR"
git clone -q --branch zig-0.16 https://github.com/ziex-dev/ziex.git "$ZIEX_DIR"
git -C "$ZIEX_DIR" checkout -q "$ZIEX_REV"

# Apply the Zig-source patches (not the door: 03 is the upstream core.ts diff, applied to the
# compiled door separately in patch-door.sh).
for p in "$PATCHES"/01-*.patch "$PATCHES"/02-*.patch "$PATCHES"/04-*.patch; do
    git -C "$ZIEX_DIR" apply "../$p"
    echo "setup-ziex: applied $(basename "$p")"
done

echo "setup-ziex: $ZIEX_DIR ready at $ZIEX_REV + 3 zig patches"
