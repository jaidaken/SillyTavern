#!/usr/bin/env bash
# Materialize the patched ziex at client/.ziex (gitignored) from the shared ziex-patched
# repository, which owns the patch files. This list is what THIS project applies; see its README.
set -euo pipefail

cd "$(dirname "$0")"

# Eighteen of the twenty-four. Five are left out ON PURPOSE and none of the reasons is proven:
#   03           the door, applied by patch-door.sh after the export. This one IS understood.
#   07 08 09     excluded by this project since before the shared repository existed. The reason
#                was never written down anywhere that survives, and a reviewer has since named a
#                plausible one: 09 frees the per-dispatch jsz event handle after a handler returns,
#                assuming every handler is synchronous. Do not re-enable without checking that.
#   10 11        they patch ziex's tailwind plugin, which this project does not compile at all.
PATCHES=(
    01-vdom-text-pointer-uaf.patch
    02-commentmarker-handle-leak.patch
    04-render-releases-marker.patch
    05-concatrawtext-leak.patch
    06-reconcile-memo.patch
    12-placement-move-order-and-raw-html-misuse.patch
    13-render-reentrancy-stale-patch-list.patch
    14-jsz-callalloc-double-free.patch
    15-render-recover-drops-vtree.patch
    16-jsz-empty-string-rangeerror.patch
    17-jsz-test-support-mock.patch
    18-render-gate-recover-seam.patch
    19-boundary-test-suite.patch
    20-request-animation-frame.patch
    21-pointer-events-delegation.patch
    22-expose-alloc-fetch-id.patch
    23-animationend-delegation.patch
    24-hydration-id-path-independent.patch
)

ZIEX_PATCHED="${ZIEX_PATCHED:-$(cd ../.. && pwd)/ziex-patched}"
[ -x "$ZIEX_PATCHED/setup-ziex.sh" ] || {
    echo "setup-ziex: no shared ziex-patched at $ZIEX_PATCHED" >&2
    echo "            clone it there, or point ZIEX_PATCHED at it" >&2
    exit 1
}

exec "$ZIEX_PATCHED/setup-ziex.sh" . "${PATCHES[@]}"
