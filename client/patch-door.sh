#!/usr/bin/env bash
# Apply D1 (readString cache stale-read/leak) to the exported ziex door. The door ships as a
# prebuilt tarball, so patch 03's core.ts diff never reaches the build; this edits the compiled JS.
set -euo pipefail

cd "$(dirname "$0")"

DOOR="${1:-dist/vendor/ziex/wasm/index.js}"
[ -f "$DOOR" ] || { echo "patch-door: $DOOR not found (run export first)" >&2; exit 1; }

python3 - "$DOOR" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

cache = """var stringCache = new Map;
function stringCacheKey(ptr, len) {
  return ptr * 65536 + len;
}
function readString(ptr, len) {
  const key = stringCacheKey(ptr, len);
  const cached = stringCache.get(key);
  if (cached !== undefined)
    return cached;
  const str = textDecoder.decode(getMemoryView().subarray(ptr, ptr + len));
  stringCache.set(key, str);
  return str;
}"""

uncached = """function readString(ptr, len) {
  return textDecoder.decode(getMemoryView().subarray(ptr, ptr + len));
}"""

# Patched state is the PRESENCE of the uncached body, never the absence of the cache markers:
# a reformatted or minified door has both markers absent while still carrying the D1 bug.
if uncached in s:
    print("patch-door: already patched, nothing to do")
    sys.exit(0)

if cache not in s:
    print("patch-door: neither the uncached readString nor the cache block found verbatim; "
          "door version changed, update patch-door.sh", file=sys.stderr)
    sys.exit(1)

p.write_text(s.replace(cache, uncached, 1))
print("patch-door: readString uncached, stringCache removed")
PY
