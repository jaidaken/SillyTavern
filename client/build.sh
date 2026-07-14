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

# Tailwind CSS: process glue/app-input.css through Tailwind v4 CLI. The entry imports app-base.css
# (existing styles) + app-responsive.css (mobile overrides) + Tailwind's utility layer. The scanner
# finds class names in .zx/.zig source files; the output overwrites dist/glue/app.css (which was
# NOT copied by export since we renamed the source to app-base.css). --minify uses Lightning CSS.
npx --yes @tailwindcss/cli -i glue/app-input.css -o dist/glue/app.css --minify
echo "tailwind glue/app-input.css -> dist/glue/app.css: $(wc -c < dist/glue/app.css) bytes"

# Private site: keep crawlers out, and give Lighthouse a valid robots.txt to parse instead of the
# SPA index.html fallback. Written before prune, which keeps it via its allowlist.
printf 'User-agent: *\nDisallow: /\n' > dist/robots.txt
./prune-dist.sh dist

echo "build.sh: done (opt=$OPT). Run ./verify.sh for the browser gate."
