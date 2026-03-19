const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zighook_mod = b.addModule("zighook", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "zighook",
        .linkage = .static,
        .root_module = zighook_mod,
    });
    b.installArtifact(lib);

    const module_tests = b.addTest(.{
        .root_module = zighook_mod,
    });
    const run_module_tests = b.addRunArtifact(module_tests);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/api_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zighook", .module = zighook_mod },
            },
            .link_libc = true,
        }),
    });
    const runtime_targets_path = switch (target.result.cpu.arch) {
        .aarch64 => "tests/support/runtime_targets_aarch64.S",
        .x86_64 => "tests/support/runtime_targets_x86_64.S",
        else => @panic("integration tests only provide native runtime targets for AArch64 and x86_64"),
    };
    integration_tests.root_module.addAssemblyFile(b.path(runtime_targets_path));
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
