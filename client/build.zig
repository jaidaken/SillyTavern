const std = @import("std");
const ziex = @import("ziex");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    // standardOptimizeOption(.preferred_optimize_mode) would replace -Doptimize with -Drelease.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;

    const app_exe = b.addExecutable(.{
        .name = "st_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // link_libc must stay unset here: ziex swaps any libc-requiring import for a server-only stub
    // in the wasm build (init.zig:518). wasm gets malloc/free from libc_shim, native from the exe.
    const md4c = b.createModule(.{ .root_source_file = b.path("app/pages/markdown.zig") });
    md4c.addIncludePath(b.path("vendor/md4c"));
    // Declarations only: wasm resolves them in libc_shim.zig, native links real libc.
    md4c.addIncludePath(b.path("vendor/md4c-libc"));
    md4c.addCSourceFiles(.{
        .root = b.path("vendor/md4c"),
        .files = &.{ "md4c.c", "md4c-html.c", "entity.c" },
        .flags = &.{ "-std=c99", "-DNDEBUG", "-fno-sanitize=undefined" },
    });
    md4c.addImport("libc_shim", b.createModule(.{
        .root_source_file = b.path("app/pages/libc_shim.zig"),
    }));

    app_exe.root_module.addImport("markdown", md4c);
    app_exe.root_module.link_libc = true;

    const install_glue = b.addInstallDirectory(.{
        .source_dir = b.path("glue"),
        .install_dir = .prefix,
        .install_subdir = "static/glue",
        .exclude_extensions = &.{".py"},
    });
    b.getInstallStep().dependOn(&install_glue.step);
    app_exe.step.dependOn(&install_glue.step);

    // Tests run Debug: ReleaseSmall strips the safety checks and allocator instrumentation the
    // alloc-failure oracle depends on.
    const test_step = b.step("test", "Run unit tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("app/pages/unit_test.zig"),
        .target = target,
        .optimize = .Debug,
    });
    test_mod.addIncludePath(b.path("vendor/md4c"));
    test_mod.addIncludePath(b.path("vendor/md4c-libc"));
    test_mod.addCSourceFiles(.{
        .root = b.path("vendor/md4c"),
        .files = &.{ "md4c.c", "md4c-html.c", "entity.c" },
        .flags = &.{ "-std=c99", "-DNDEBUG", "-fno-sanitize=undefined" },
    });
    test_mod.addImport("libc_shim", b.createModule(.{
        .root_source_file = b.path("app/pages/libc_shim.zig"),
    }));
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
        .cli = .{
            .steps = .{ .serve = "serve", .@"export" = "export" },
        },
        .client = .{
            .jsglue_href = "/glue/main.js",
            .jsglue_install_subdir = "static/vendor/ziex",
        },
    });
    _ = &ziex_b;
}
