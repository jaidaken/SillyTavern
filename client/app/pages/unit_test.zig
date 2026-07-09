//! Aggregator for `zig build test`. The runner only sees tests reachable from the compilation
//! root, so every test-bearing module is imported here.
//!
//! `store.zig`, `sanitized.zig` and the `.zx` components depend on the ziex `zx` module and the
//! wasm `env` imports, so they are covered by `client/verify.sh` against a real browser instead.

comptime {
    _ = @import("quotes.zig");
    _ = @import("libc_shim");
    _ = @import("markdown.zig");
}
