const std = @import("std");

fn addExample(
    b: *std.Build,
    zighook_mod: *std.Build.Module,
    runtime_targets_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source_path: []const u8,
    runtime_targets_asm: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zighook", .module = zighook_mod },
                .{ .name = "runtime_targets", .module = runtime_targets_mod },
            },
            .link_libc = true,
        }),
    });
    exe.root_module.addAssemblyFile(runtime_targets_asm);
    return exe;
}

fn addPayloadLibrary(
    b: *std.Build,
    zighook_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source_path: []const u8,
    constructor_asm: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const dylib = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zighook", .module = zighook_mod },
            },
            .link_libc = true,
        }),
    });
    dylib.root_module.addAssemblyFile(constructor_asm);
    return dylib;
}

fn addPreloadTargetBuild(
    b: *std.Build,
    output_name: []const u8,
    source_path: []const u8,
) struct { step: *std.Build.Step.Run, output: std.Build.LazyPath } {
    const cc = b.addSystemCommand(&.{
        "cc",
        "-O0",
        "-g",
        "-Wl,-export_dynamic",
        "-o",
    });
    const output = cc.addOutputFileArg(output_name);
    cc.addFileArg(b.path(source_path));
    return .{ .step = cc, .output = output };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runtime_targets_asm = b.path("examples/support/runtime_targets_aarch64_macos.S");
    const replay_targets_asm = b.path("examples/support/replay_targets_aarch64_macos.S");
    const preload_constructor_asm = b.path("examples/preload/constructor_aarch64_macos.S");

    const mod = b.addModule("zighook", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const runtime_targets_mod = b.createModule(.{
        .root_source_file = b.path("examples/support/runtime_targets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zighook",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zighook", .module = mod },
            },
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.root_module.addAssemblyFile(runtime_targets_asm);
    mod_tests.root_module.addAssemblyFile(replay_targets_asm);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const examples_step = b.step("examples", "Build all example executables");
    const example_specs = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "example_patchcode_add_to_mul", .path = "examples/patchcode_add_to_mul/main.zig" },
        .{ .name = "example_instrument_with_original", .path = "examples/instrument_with_original/main.zig" },
        .{ .name = "example_instrument_no_original", .path = "examples/instrument_no_original/main.zig" },
        .{ .name = "example_inline_hook_signal", .path = "examples/inline_hook_signal/main.zig" },
        .{ .name = "example_inline_hook_jump", .path = "examples/inline_hook_jump/main.zig" },
        .{ .name = "example_instrument_unhook_restore", .path = "examples/instrument_unhook_restore/main.zig" },
    };

    inline for (example_specs) |spec| {
        const example_exe = addExample(
            b,
            mod,
            runtime_targets_mod,
            target,
            optimize,
            spec.name,
            spec.path,
            runtime_targets_asm,
        );
        examples_step.dependOn(&example_exe.step);
    }

    const payload_inline_hook_signal = addPayloadLibrary(
        b,
        mod,
        target,
        optimize,
        "zighook_payload_inline_hook_signal",
        "examples/preload/payload_inline_hook_signal.zig",
        preload_constructor_asm,
    );
    const payload_inline_hook_jump = addPayloadLibrary(
        b,
        mod,
        target,
        optimize,
        "zighook_payload_inline_hook_jump",
        "examples/preload/payload_inline_hook_jump.zig",
        preload_constructor_asm,
    );
    const preload_target = addPreloadTargetBuild(
        b,
        "zighook_preload_target_add",
        "examples/preload/target_add.c",
    );

    b.installArtifact(payload_inline_hook_signal);
    b.installArtifact(payload_inline_hook_jump);
    b.getInstallStep().dependOn(&b.addInstallBinFile(preload_target.output, "zighook_preload_target_add").step);

    examples_step.dependOn(&payload_inline_hook_signal.step);
    examples_step.dependOn(&payload_inline_hook_jump.step);
    examples_step.dependOn(&preload_target.step.step);

    const preload_examples_step = b.step("preload-examples", "Build DYLD preload payload dylibs and the C smoke target");
    preload_examples_step.dependOn(&payload_inline_hook_signal.step);
    preload_examples_step.dependOn(&payload_inline_hook_jump.step);
    preload_examples_step.dependOn(&preload_target.step.step);

    const smoke_signal = b.addSystemCommand(&.{ "env", "TARGET_EXPECT=42" });
    smoke_signal.addPrefixedFileArg("DYLD_INSERT_LIBRARIES=", payload_inline_hook_signal.getEmittedBin());
    smoke_signal.addFileArg(preload_target.output);

    const smoke_jump = b.addSystemCommand(&.{ "env", "TARGET_EXPECT=6" });
    smoke_jump.addPrefixedFileArg("DYLD_INSERT_LIBRARIES=", payload_inline_hook_jump.getEmittedBin());
    smoke_jump.addFileArg(preload_target.output);

    const preload_smoke_step = b.step("preload-smoke", "Run DYLD_INSERT_LIBRARIES smoke tests against a C target");
    preload_smoke_step.dependOn(&smoke_signal.step);
    preload_smoke_step.dependOn(&smoke_jump.step);
}
