# perf + trusted-types hardening (sillybeta client)
status=done pane=%0 session=claude-7040-1147 ts=1783737012
outcome: TrustedTypes DOM-XSS hardening SHIPPED + verified live under enforcing CSP (12/12 render, console clean). lib+css minify shipped. earlier same session: staggered top-to-bottom load reveal, 12-msg example, placeholder-flash fix, SEO (meta+robots), edge security headers. all deployed to sillybeta.jaidaken.dev via bigboy atomic-swap + edge rebuild.
decisions: TT = ONE 'default' passthrough policy at glue boot (browser auto-applies to EVERY innerHTML incl the ziex door) NOT per-sink wrap; edge CSP = 'trusted-types default dompurify; require-trusted-types-for script' (dompurify needs its own policy); passthrough safe bc HTML already DOMPurify-sanitized. main.js EXCLUDED from minify pending the minify-causal-vs-load-race verdict.
files: client/glue/main.js (default TT policy) d67739012 ; client/build.sh (lib+css minify) 6b73a3b57 ; ~/nixos-config/containers/edge.nix (CSP) 6cd774d + later commit.
dropped: the 3-failure TT bug chain (lost m-tt integration, wrong minify blame, wrong st-html policy name), the rel=noopener grep-pattern saga, streamed-capture flake diagnoses, all tool-output noise.
next: read client/.claude/handoffs/fa5a5b08-a9b0-42d7-a215-d208b69b40a7.md RESUME_NEXT; read m-mainjs minify causality verdict; re-enable main.js minify (proven safe); resolve font-preload vs verify.sh-old-headless tradeoff.

RESUMED 2026-07-11 (post-compact), ALL residuals DONE + DEPLOYED:
- main.js minify RE-ENABLED (build.sh: classic-IIFE, plain --minify, 30.5KB->11KB). commit f8c2abda9.
- font preload LANDED (layout.zx: Newsreader-latin.woff2 crossorigin, LCP serif). commit 7eb9eaae3.
- ROOT CAUSE of the whole minify/preload "regression" saga: NOT the code. ~30 orphaned devserve.py harness servers (leaked from crashed team members across the session) loaded the machine + starved chrome --virtual-time-budget, so --dump-dom captured a PRE-hydration empty DOM -> verify.sh false-failed deterministically. Killed the orphans; baseline green 2x, minify green 3x, preload green 3x. m-tt's preload "regression" was the SAME artifact (m-tt even flagged the env confound).
- CSP-ENFORCEMENT re-verified on the MINIFIED build via Playwright (verify.sh does NOT enforce CSP so its green never proved the minified TT policy): 12/12 rendered, chat-root hydrated, 0 console errors under require-trusted-types-for 'script'; trusted-types default dompurify.
- DEPLOYED to bigboy via atomic swap (sillybeta.old rollback kept): live main.js=11073 bytes, preload present. edge healthy (sillybeta 302 auth, kitcrew 200, silly 302, Caddy active).
OPEN (surfaced to operator, his call): verify.sh flakes under machine load (fixed --virtual-time-budget races wasm hydration). durable fix = event-driven wait for chat-root.hydrated sentinel, or a startup sweep of stale devserve orphans. NOT done - a harness redesign with tradeoffs.
