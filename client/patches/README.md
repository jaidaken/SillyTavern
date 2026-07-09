# ziex patches (against v0.1.0-dev.1259, commit 26f5945)

Four fixes for confirmed ziex defects, applied to the fetched ziex source before build.
Each is proven; see the wiki note `wasm-zig-browser-ui/raw/notes/2026-07-09-ziex-three-defects.md`.
All four are candidates to upstream as PRs; drop the patch once merged.

- 01 vdom text pointer use-after-free: the retained vtree re-pointed a text node only on change, so an unchanged node held a freed pointer. Hoist the re-point out of the `if`.
- 02 findCommentMarker + CommentMarker handle leak: the marker walk never released its jsz object handles, and CommentMarker had no deinit, leaking handles every render. Release non-retained walk handles; add CommentMarker.deinit.
- 03 readString cache stale-read + unbounded leak: the door cached decoded strings by pointer forever, returning stale text on address reuse and growing without bound. Remove the cache (source diff; the shipped tarball's compiled index.js needs the equivalent edit).
- 04 render releases the marker: Client.render obtained a marker every render and dropped it; add `defer marker.deinit()`.
