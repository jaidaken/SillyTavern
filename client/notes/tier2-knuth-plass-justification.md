---
description: Deferred Tier-2 exploration: Knuth-Plass optimal justification on message-seal, its design, honest caveats, and the prototype-and-judge gate before committing.
tags: [client, css, typography, reading, knuth-plass, line-breaking, design, deferred]
date: 2026-07-11
---

# TIER 2: KNUTH-PLASS JUSTIFICATION (DEFERRED, EXPLORE LATER)

status = NOT committed. Tier 1 (native `text-align: justify` + `hyphens: auto`, gated to long
messages) ships first + owns the reading surface. THIS = the optional print-quality upgrade, kept as
an experiment to PROTOTYPE + A/B, not a promise. operator (2026-07-11): do Tier 1 now, doc Tier 2.

## WHY IT EXISTS

browsers line-break GREEDILY (line at a time) -> justified text gets whitespace RIVERS. Knuth-Plass
(KP) breaks the WHOLE paragraph optimally (min total demerits, demerit = (ideal_len - actual_len)^2
per line + hyphenation/penalty terms) -> even color, print/LaTeX quality. this is the ONLY thing the
native path genuinely can NOT do. operator prefers justified text, so the ceiling is worth knowing.

## DESIGN (if built)

- RUN ON SEAL ONLY. hook = the streaming->false transition (glue `__st_stream_end`, or a Zig seal
  signal). one KP pass over that sealed `.mes_text`. NEVER per streamed token -> zero streaming cost.
- streaming message stays Tier-1 native justify while tokens arrive; upgrades to KP on seal.
- MEASUREMENT: KP needs per-word widths. cheap path = canvas `measureText` w/ the real Newsreader
  font from the glue. (accuracy caveat below.)
- OUTPUT: KP chosen break points -> apply so each line justifies clean (insert breaks / adjust
  spacing). ragged-right variant possible too (KP minimizes raggedness w/o forcing justify).
- PERF GUARD: `content-visibility: auto` on sealed off-screen `.mes` (Tier 1 already adds this) means
  most sealed messages never lay out -> KP re-layout is only paid for on-screen messages. KP itself is
  near-linear (SMAWK on the Monge matrix); a few-hundred-word para = sub-ms.
- ENGINE CHOICE (decide at build):
  - native ZIG KP: matches stack, no JS dep, algorithm is small (DAG shortest-path, see the Medium
    ref). most on-brand. more work + the measurement-accuracy risk is ours to get right.
  - `robertknight/tex-linebreak` (193 stars, MIT, pure TS, DOM-ready, active 2026-07): proven, faster
    to wire, DOES the measure+break+DOM-apply carefully. cost = a JS dep + single-maintainer.

## HONEST CAVEATS (why it is NOT a slam dunk)

1. MARGINAL DELTA. Tier-1 native-justify + hyphenation already gets ~85%. KP is the last stretch that
   TYPOGRAPHERS notice + most readers will not. prototype MUST be judged side-by-side; if the eye can
   not tell KP from Tier-1-hyphenated, KP is NOT worth the complexity.
2. REFLOW POP. on seal the message re-justifies from the Tier-1 layout to the KP layout -> line breaks
   visibly JUMP at the seal moment. a real UX cost (CLS-adjacent). mitigations: cross-fade, or only KP
   when the message is off the initial viewport, or accept it.
3. MEASUREMENT ACCURACY. canvas `measureText` may not exactly match the browser's final paint (variable
   font + `opsz` optical sizing + sub-pixel + letter-spacing). a mismatch = an overfull/underfull line.
   this is precisely why the KP-WASM libs bundle HarfBuzz. native-Zig-via-measureText carries this risk;
   `tex-linebreak` handles it more carefully.
4. SHORT MESSAGES. same gate as Tier 1: only justify/KP messages above the line threshold; short RP
   turns (`*She nods.*`) stay ragged. KP inherits Tier 1's `.mes-justify` gate.

## THE GATE (do this before committing)

PROTOTYPE one sealed message w/ KP, put it beside the Tier-1-hyphenated version, judge whether the
difference is VISIBLE to a normal reader. keep only if yes. this is a design-probe, disposable, not a
build commitment.

## SEE ALSO

- [Ziex reactivity + reconcile refactor plan](ziex-refactor-plan.md) - the memo/seal machinery KP hooks.
- wiki (deeper research + sources): `~/.claude/wiki/topics/web-design/raw/notes/2026-07-11-web-reading-typography.md`.
- KP algorithm explainer: https://medium.com/code-and-coffee/line-breakings-directed-acyclic-graphs-and-matrix-fun-or-the-knuth-plass-algorithm-5c008b0b31bb
