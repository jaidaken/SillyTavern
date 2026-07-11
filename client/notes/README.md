---
description: Index of the client rebuild's audit, backlog, and refactor-design notes.
tags: [index, audit, client]
date: 2026-07-10
---

# client/notes

Audit + design notes for the WASM/Zig SillyTavern client rebuild.

## Consolidated

- [bug-register-2026-07-10.md](bug-register-2026-07-10.md) - COMPLETE register of every finding across all
  audits (W05 235 + prior backlog + resolved Phase 0). One line per finding, grouped by subsystem.
- [ziex-refactor-plan.md](ziex-refactor-plan.md) - deep design for the ziex reactive-model refactor:
  mechanism, probe MAJOR result, memoization + region decomposition, the UAF coupling constraint, test plan.
- [tier1-reading-surface-spec.md](tier1-reading-surface-spec.md) - APPROVED, ready-to-build spec: native
  justified prose (gated to long messages), reading-controls panel, settings sub-panel restructure, scoped
  to the message area only.
- [tier2-knuth-plass-justification.md](tier2-knuth-plass-justification.md) - DEFERRED reading-surface upgrade:
  Knuth-Plass optimal justification on message-seal, the design, honest caveats (marginal delta, reflow pop,
  measurement risk), and the prototype-and-judge gate. Tier 1 (native justify+hyphens) ships first.

## Source audits

- [audit-2026-07-10.md](audit-2026-07-10.md) - the prior exhaustive backlog (3 fresh-eyes passes) + the
  locked fix-phase plan + the design-probe MAJOR result + the designed plan.
- [audit-w05-summary.md](audit-w05-summary.md) - synthesis of the W05 exhaustive audit (5 members).
- [audit-w05-glue.md](audit-w05-glue.md) - JavaScript glue (28).
- [audit-w05-css.md](audit-w05-css.md) - app.css vs the webdesign pack (65).
- [audit-w05-scripts.md](audit-w05-scripts.md) - build / dev / verify / deploy tooling (67).
- [audit-w05-ziex.md](audit-w05-ziex.md) - ziex subsystems the app reaches (34).
- [audit-w05-zig.md](audit-w05-zig.md) - the app's own Zig + .zx (41).
