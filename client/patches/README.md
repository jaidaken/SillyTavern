---
description: Superseded local copy of the ziex patch series; the live series is the shared ziex-patched repository.
tags: [ziex, patches, superseded]
date: 2026-07-31
---

# Superseded

These files are the old local copy of the ziex patch series. Nothing in this directory is applied
any more. `../setup-ziex.sh` names this project's applied list and hands it to the shared
`ziex-patched` repository, which owns the patch files and the generic door edits, and which
zomboid-manager consumes too.

- [EXCLUSION-07-08-09](./EXCLUSION-07-08-09.md) - why 07, 08 and 09 are unapplied here. Settled
  2026-07-31: it was an omission, not a decision. Commit 6d91a78f4 added all three patch files and
  changed zero lines of `setup-ziex.sh`, while its own message says they are applied by it. Carries
  the per-patch safety verdict and what is still owed before wiring them.

**What this project applies is unchanged**: the same eighteen as before, `01 02 04 05 06` and
`12` through `24`. Not 07, 08 or 09. Not 10 or 11. The list moved into `../setup-ziex.sh`, where a
reader can see it without opening a second repository, but no patch was added or removed and the
resulting `dist/` is byte-identical to the last build made from this directory, `main.wasm`
included.

The shared files are shared; the applied list is not. Only the files were ever the duplication
problem.

## The 07, 08, 09 exclusion is now written down as unexplained

This tree excluded those three since before the shared repository existed, and the reason survives
nowhere: not in the old notes here, not in the wiki note they cited (which does not exist), not in
the section files. `ziex-patched/README.md` records that, records the one plausible mechanism a
later reviewer named (patch 09 frees the per-dispatch jsz event handle after a handler returns,
assuming every handler is synchronous), and states plainly that preserving an unexplained decision
is its own defect rather than a safe default. Read that section before touching the list.

## Door edits

D1 through D6, D8 and D9 are generic ziex runtime correctness and moved to the shared repository.
D7, D10, D11 and D12 are this application's features and stayed in `../patch-door.sh`, which runs
immediately after the shared script against the same file. The resulting door is byte-identical to
the one the single old script produced.

## Patch 15

Its `unregisterVElement` hunk carries two lines of leading context in the shared copy rather than
three, so that one file applies both to this project's list and to a list containing 09. Nothing
else about it changed, and the source it produces here is byte-identical to what this directory
produced.

This directory is kept only so the change can be read against what it replaced. Delete it once that
is no longer useful.
