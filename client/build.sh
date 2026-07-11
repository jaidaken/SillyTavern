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

# Minify the browser-fetched dist assets (sources stay readable). Vendor mjs keep --format=esm so
# the dynamic-import() default-export shape survives; --allow-overwrite writes each file over itself.
for f in dist/glue/vendor/purify.es.mjs dist/glue/vendor/hljs.mjs; do
    b=$(wc -c < "$f")
    npx --yes esbuild "$f" --minify --format=esm --allow-overwrite --outfile="$f"
    echo "minify $f: $b -> $(wc -c < "$f") bytes"
done
# main.js is NOT minified: esbuild mangles the ?stream dev-probe harness verify.sh drives, and a
# minified glue is unverifiable. It is only ~30KB (~10KB gzip); the win is in the vendored libs above.
for f in dist/glue/app.css; do
    b=$(wc -c < "$f")
    npx --yes esbuild "$f" --minify --allow-overwrite --outfile="$f"
    echo "minify $f: $b -> $(wc -c < "$f") bytes"
done

# Private site: keep crawlers out, and give Lighthouse a valid robots.txt to parse instead of the
# SPA index.html fallback. Written before prune, which keeps it via its allowlist.
printf 'User-agent: *\nDisallow: /\n' > dist/robots.txt
./prune-dist.sh dist

echo "build.sh: done (opt=$OPT). Run ./verify.sh for the browser gate."
