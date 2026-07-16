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

# zx is a separate module, so the suite above cannot see tests inside .ziex: an `expect(false)` in
# .ziex/src/runtime/core/vdom.zig still reports 426/426 (verified 2026-07-16). Patch 12's regression
# test only runs here.
(cd .ziex && zig build test)

zig build "-Doptimize=$OPT"
zig build export "-Doptimize=$OPT"
# Order is load-bearing: export writes dist, patch-door edits the door in place, prune trims the
# unpruned ziex npm tree export copied in. verify.sh then runs against the pruned artifact.
./patch-door.sh

# Minify the browser-fetched dist assets (sources stay readable). ESM keeps --format=esm so the
# dynamic-import() shape survives; --allow-overwrite writes each file over itself. The ziex door is
# minified here, AFTER patch-door: verify.sh asserts the patch by minify-stable signals, not source.
for f in dist/glue/vendor/purify.es.mjs dist/glue/vendor/hljs.mjs dist/vendor/ziex/wasm/index.js; do
    b=$(wc -c < "$f")
    npx --yes esbuild "$f" --minify --format=esm --allow-overwrite --outfile="$f"
    echo "minify $f: $b -> $(wc -c < "$f") bytes"
done
# custom.js (classic-script IIFE, deps via dynamic import()) takes plain --minify: no
# --format=esm, so the non-module script contract survives. esbuild picks the loader by extension.
b=$(wc -c < dist/glue/custom.js)
npx --yes esbuild dist/glue/custom.js --minify --allow-overwrite --outfile=dist/glue/custom.js
echo "minify dist/glue/custom.js: $b -> $(wc -c < dist/glue/custom.js) bytes"

# Tailwind now compiles inside `zig build` (ziex's plugin, patch 10) and lands in zig-out/static;
# the export step copies it to dist. Nothing to run here.
echo "tailwind -> dist/glue/app.css: $(wc -c < dist/glue/app.css) bytes (built by zig)"

# Private site: keep crawlers out, and give Lighthouse a valid robots.txt to parse instead of the
# SPA index.html fallback. Written before prune, which keeps it via its allowlist.
printf 'User-agent: *\nDisallow: /\n' > dist/robots.txt
./prune-dist.sh dist

echo "build.sh: done (opt=$OPT). Run ./verify.sh for the browser gate."
