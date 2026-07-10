#!/usr/bin/env bash
# zx export copies the whole ziex npm tree into dist/; only these paths are ever fetched.
set -euo pipefail

DIST="${1:-dist}"
# A trailing slash would make the rel= strip pattern never match, so every file misses KEEP
# and the rm below wipes the tree. Strip them before any use.
while [ "$DIST" != "/" ] && [ "${DIST%/}" != "$DIST" ]; do DIST="${DIST%/}"; done
[ -n "$DIST" ] && [ "$DIST" != "/" ] || { echo "refusing to prune: $DIST" >&2; exit 1; }
# Anchor the target. A mistyped DIST=".." or "$HOME" passes every check above and rm -f below
# would wipe the caller's tree; refuse anything whose resolved basename does not contain "dist".
RESOLVED=$(realpath -e "$DIST") || { echo "no such dir: $DIST" >&2; exit 1; }
case "$(basename "$RESOLVED")" in
    *dist*) ;;
    *) echo "refusing to prune: $RESOLVED (basename carries no 'dist'; not an export tree)" >&2; exit 1 ;;
esac

KEEP=(
    "index.html"
    "assets/_/main.wasm"
    "glue/main.js"
    "glue/app.css"
    "glue/favicon.png"
    "glue/vendor/hljs.mjs"
    "glue/vendor/purify.es.mjs"
    "glue/vendor/hljs-theme.css"
    "vendor/ziex/wasm/index.js"
)

before_files=$(find "$DIST" -type f | wc -l)
before_gz=0
while IFS= read -r f; do
    before_gz=$((before_gz + $(gzip -9 -c "$f" | wc -c)))
done < <(find "$DIST" -type f)

# Exact membership, not a regex: a KEEP path carrying an ERE metacharacter (+?(){}|) would slip
# past a grep -qE anchor and be deleted. An associative array matches the literal path instead.
declare -A keep_set
for k in "${KEEP[@]}"; do
    [ -f "$DIST/$k" ] || { echo "expected file missing: $DIST/$k" >&2; exit 1; }
    keep_set["$k"]=1
done

while IFS= read -r f; do
    rel="${f#"$DIST"/}"
    [ -n "${keep_set[$rel]:-}" ] || rm -f "$f"
done < <(find "$DIST" -type f)

find "$DIST" -type d -empty -delete

# The prune is only safe if every browser-fetched file survived it: a bug here surfaces as a
# broken fetch at runtime, in the deployed build. Re-assert KEEP before reporting success.
for k in "${KEEP[@]}"; do
    [ -f "$DIST/$k" ] || { echo "prune deleted a KEEP file: $DIST/$k" >&2; exit 1; }
done

after_files=$(find "$DIST" -type f | wc -l)
after_gz=0
while IFS= read -r f; do
    after_gz=$((after_gz + $(gzip -9 -c "$f" | wc -c)))
done < <(find "$DIST" -type f)

echo "pruned $DIST: $before_files -> $after_files files, $before_gz -> $after_gz bytes gzipped"
