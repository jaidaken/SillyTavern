#!/usr/bin/env bash
# Materialize patched ziex at client/.ziex (gitignored) from client/patches/; delete + rerun to rebuild.
# The door patch (D1) is in the prebuilt tarball, not source, so it is applied post-export in patch-door.sh.
set -euo pipefail

cd "$(dirname "$0")"

ZIEX_REV="26f594531d302421f4e53b52c9b3c653093c1392"
ZIEX_DIR=".ziex"
PATCHES="patches"

cur=none
if [ -d "$ZIEX_DIR/.git" ]; then
    cur=$(git -C "$ZIEX_DIR" rev-parse HEAD 2>/dev/null || echo none)
fi

if [ "$cur" = "$ZIEX_REV" ]; then
    # Reuse the clone but discard prior patch application or hand edits, so patches always
    # apply to the pinned tree and never stack or silently fail to apply.
    git -C "$ZIEX_DIR" reset -q --hard "$ZIEX_REV"
    git -C "$ZIEX_DIR" clean -qfd
    echo "setup-ziex: $ZIEX_DIR reset to pinned $ZIEX_REV"
else
    rm -rf "$ZIEX_DIR"
    git clone -q --branch zig-0.16 https://github.com/ziex-dev/ziex.git "$ZIEX_DIR"
    git -C "$ZIEX_DIR" checkout -q "$ZIEX_REV"
    echo "setup-ziex: cloned $ZIEX_DIR at pinned $ZIEX_REV"
fi

# Apply the Zig-source patches (not the door: 03 is the upstream core.ts diff, applied to the
# compiled door separately in patch-door.sh). 10 patches the tailwind plugin's class scanner.
# 11 fixes a UAF in that plugin's dep-file writer (deps freed before writeDepFile reads them).
# 12 orders PLACEMENT/MOVE by reference node so the vtree and the DOM cannot drift apart.
# 14 gives convertValue sole ownership of the returned handle: callAlloc/getAlloc also freed it on
# an error, so a type mismatch (eg call(void) on an async helper) freed one jsz slot twice.
# 15 adds __zx_render_recover: a throw through wasm skips 13's `defer render_gate.exit()`, so the
# gate stays held and the page never renders again. Must apply AFTER 13 (it edits 13's own files).
for p in "$PATCHES"/01-*.patch "$PATCHES"/02-*.patch "$PATCHES"/04-*.patch "$PATCHES"/05-*.patch "$PATCHES"/06-*.patch "$PATCHES"/10-*.patch "$PATCHES"/11-*.patch "$PATCHES"/12-*.patch "$PATCHES"/13-*.patch "$PATCHES"/14-*.patch "$PATCHES"/15-*.patch "$PATCHES"/16-*.patch; do
    git -C "$ZIEX_DIR" apply "../$p"
    echo "setup-ziex: applied $(basename "$p")"
done

echo "setup-ziex: $ZIEX_DIR ready at $ZIEX_REV + 12 patches"
