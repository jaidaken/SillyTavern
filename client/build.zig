const std = @import("std");
const ziex = @import("ziex");
const tailwindcss = @import("tailwindcss");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    // standardOptimizeOption(.preferred_optimize_mode) would replace -Doptimize with -Drelease.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;

    // Off by default so the render counter and its door export never reach the production wasm.
    // The render-count harness turns it on through the export CLI: `export -- --build-args=-Dinstrument`.
    const instrument = b.option(bool, "instrument", "Compile the render-count instrumentation") orelse false;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "instrument", instrument);

    const app_exe = b.addExecutable(.{
        .name = "st_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    app_exe.root_module.addImport("build_options", build_opts.createModule());

    const md4c = b.createModule(.{ .root_source_file = b.path("app/pages/markdown.zig") });
    addMd4c(b, md4c, optimize);
    app_exe.root_module.addImport("markdown", md4c);
    // The exe links libc; the md4c module deliberately does not, so ziex can stub its libc imports
    // for the wasm build (init.zig:518). wasm gets malloc/free from libc_shim, native from the exe.
    app_exe.root_module.link_libc = true;

    const install_glue = b.addInstallDirectory(.{
        .source_dir = b.path("glue"),
        .install_dir = .prefix,
        .install_subdir = "static/glue",
        // Only .py. Excluding .css here would also drop glue/vendor/hljs-theme.css, which
        // prune-dist requires; the source stylesheets it copies are pruned anyway.
        .exclude_extensions = &.{".py"},
    });
    b.getInstallStep().dependOn(&install_glue.step);
    app_exe.step.dependOn(&install_glue.step);

    // Source globs live in app-input.css: `sources` is left empty because the plugin readFileSyncs
    // each entry and swallows a directory as EISDIR.
    const css = tailwindcss.addBuild(b, .{
        .name = "app",
        .config = .{ .input = b.path("glue/app-input.css"), .minify = true },
    });
    const install_css = b.addInstallFile(css.file, "static/glue/app.css");
    b.getInstallStep().dependOn(&install_css.step);
    app_exe.step.dependOn(&install_css.step);

    // Tests run Debug: ReleaseSmall strips the safety checks and allocator instrumentation the
    // alloc-failure oracle depends on.
    const test_step = b.step("test", "Run unit tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("app/pages/unit_test.zig"),
        .target = target,
        .optimize = .Debug,
    });
    addMd4c(b, test_mod, .Debug);
    test_mod.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_mod })).step);

    // zig test only discovers tests reachable by file path from the compilation root, so a module
    // root needs its own artifact. libc_shim cannot be file-imported: markdown owns it as a module.
    const shim_test_mod = b.createModule(.{
        .root_source_file = b.path("app/pages/libc_shim.zig"),
        .target = target,
        .optimize = .Debug,
    });
    shim_test_mod.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = shim_test_mod })).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "app", "build.zig" }, .check = true });
    const check_step = b.step("check", "zig fmt --check");
    check_step.dependOn(&fmt_check.step);

    var ziex_b = try ziex.init(b, app_exe, .{
        .app = .{ .base_path = "/client" },
        .cli = .{
            .steps = .{ .serve = "serve", .@"export" = "export" },
        },
        .client = .{
            .jsglue_href = "/glue/custom.js",
            .jsglue_install_subdir = "static/vendor/ziex",
        },
    });
    _ = &ziex_b;
}

/// Attach the md4c C sources, its include paths, and the libc_shim import to `mod`. Shared by the
/// app module and the test module so the source set and flags have one owner.
fn addMd4c(b: *std.Build, mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) void {
    mod.addIncludePath(b.path("vendor/md4c"));
    // Declarations only: wasm resolves them in libc_shim.zig, native links real libc.
    mod.addIncludePath(b.path("vendor/md4c-libc"));
    // -DNDEBUG compiles out md4c's internal asserts. Keep them in the Debug test build so the
    // alloc-failure oracle exercises an assert-checked md4c, not a stripped one.
    const md4c_flags: []const []const u8 = if (optimize == .Debug)
        &.{ "-std=c99", "-fno-sanitize=undefined" }
    else
        &.{ "-std=c99", "-DNDEBUG", "-fno-sanitize=undefined" };
    mod.addCSourceFiles(.{
        .root = b.path("vendor/md4c"),
        .files = &.{ "md4c.c", "md4c-html.c", "entity.c" },
        .flags = md4c_flags,
    });
    mod.addImport("libc_shim", b.createModule(.{
        .root_source_file = b.path("app/pages/libc_shim.zig"),
    }));
}
