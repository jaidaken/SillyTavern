# ziex patches (against v0.1.0-dev.1259, commit 26f5945)

Fixes for confirmed ziex defects, applied to the fetched ziex source before build.
Each is proven; see the wiki note `wasm-zig-browser-ui/raw/notes/2026-07-09-ziex-three-defects.md`.
All are candidates to upstream as PRs; drop the patch once merged.

Which patches actually apply is the explicit glob list in `setup-ziex.sh` (01 02 04 05 06 10 11 12),
NOT this file and NOT the presence of a file in this directory: 03 is the door (applied post-export
by `patch-door.sh` because the door ships prebuilt), and 07/08/09 exist but are deliberately unwired.

WARNING for anyone adding a test to a patch: a test placed in `.ziex/src/**` NEVER RUNS. Zig only
discovers tests reachable by file path from the compilation root and `zx` is a separate module, so
`zig build test` reports all-pass with an `expect(false)` sitting in `.ziex/src/runtime/core/vdom.zig`
(verified 2026-07-16). The tests patches 05 and 06 added there have therefore never run once. Put
tests in `.ziex/test/**`, which `build.sh` now runs as its own suite.

- 01 vdom text pointer use-after-free: the retained vtree re-pointed a text node only on change, so an unchanged node held a freed pointer. Hoist the re-point out of the `if`.
- 02 findCommentMarker + CommentMarker handle leak: the marker walk never released its jsz object handles, and CommentMarker had no deinit, leaking handles every render. Release non-retained walk handles; add CommentMarker.deinit.
- 03 readString cache stale-read + unbounded leak: the door cached decoded strings by pointer forever, returning stale text on address reuse and growing without bound. Remove the cache (source diff; the shipped tarball's compiled index.js needs the equivalent edit).
- 04 render releases the marker: Client.render obtained a marker every render and dropped it; add `defer marker.deinit()`.
- 05 concatRawText leak: the escaping-none diff built both sides' raw text and freed neither. (Its test is in `.ziex/src/**` and has never run; see the warning above.)
- 06 reconcile memo fast path: an unchanged keyed component keeps its old vnode without being resolved or diffed, so a sealed message costs nothing per render. (Same: its test has never run.)
- 10 tailwind oxide scanner: the plugin's class scanner dropped classes the app really uses.
- 12 PLACEMENT/MOVE order + raw-html misuse: the two ordered the DOM by REFERENCE node but the vtree by INDEX, so the two disagreed (traced: a placeholder replaced by many rows leaves the DOM correct and the vtree REVERSED). Both now derive position from `reference_id` alone, and `PatchData.PLACEMENT.index` / `MOVE.new_index` are DELETED so a second source of position is unrepresentable rather than merely unused. Also: `createPlatformNodes`' escaping-none branch claimed non-text children "fall back to normal node creation below" and instead returned immediately, silently never creating them; it now reports the misuse. Regression test in `.ziex/test/core/vdom.zig`, proven red (`expected 16, found 64`) against the unpatched ordering rule.
- 11 tailwind dep-file use-after-free: the plugin duped each discovered dependency into a block-scoped arena that `deinit`s before `writeDepFile` reads them, so `writeDepFile`'s own buffer reused the freed pages and corrupted a dep path in `output.d`. zig then `openat`s the mangled path and the build fails `FileNotFound`. Length-sensitive (surfaces on the longer `SillyTavern/client` abs path, not shorter worktree paths). Dupe deps into the process-lifetime arena instead.
