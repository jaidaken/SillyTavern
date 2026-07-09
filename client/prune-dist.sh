#!/usr/bin/env bash
# zx export copies the whole ziex npm tree into dist/; only these paths are ever fetched.
set -euo pipefail

DIST="${1:-dist}"
[ -d "$DIST" ] || { echo "no such dir: $DIST" >&2; exit 1; }

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

keep_re=""
for k in "${KEEP[@]}"; do
    [ -f "$DIST/$k" ] || { echo "expected file missing: $DIST/$k" >&2; exit 1; }
    keep_re="${keep_re}${keep_re:+|}$(printf '%s' "$k" | sed 's/[.[\*^$]/\\&/g')"
done

while IFS= read -r f; do
    rel="${f#"$DIST"/}"
    printf '%s' "$rel" | grep -qE "^($keep_re)$" || rm -f "$f"
done < <(find "$DIST" -type f)

find "$DIST" -type d -empty -delete

after_files=$(find "$DIST" -type f | wc -l)
after_gz=0
while IFS= read -r f; do
    after_gz=$((after_gz + $(gzip -9 -c "$f" | wc -c)))
done < <(find "$DIST" -type f)

echo "pruned $DIST: $before_files -> $after_files files, $before_gz -> $after_gz bytes gzipped"
