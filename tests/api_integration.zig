const builtin = @import("builtin");
const std = @import("std");

const zighook = @import("zighook");

extern fn demo_add_target(a: i32, b: i32) callconv(.c) i32;
extern fn demo_add_patchpoint() callconv(.c) void;
extern fn demo_direct_call_target(a: i32, b: i32) callconv(.c) i32;
extern fn demo_direct_call_patchpoint() callconv(.c) void;
extern fn demo_direct_jump_target() callconv(.c) i32;
extern fn demo_direct_jump_patchpoint() callconv(.c) void;
extern fn demo_rip_indirect_call_target(a: i32, b: i32) callconv(.c) i32;
extern fn demo_rip_indirect_call_patchpoint() callconv(.c) void;
extern fn demo_rip_indirect_jump_target() callconv(.c) i32;
extern fn demo_rip_indirect_jump_patchpoint() callconv(.c) void;
extern fn demo_rip_load_target() callconv(.c) i32;
extern fn demo_rip_load_patchpoint() callconv(.c) void;
extern fn demo_conditional_branch_target(value: i32) callconv(.c) i32;
extern fn demo_conditional_branch_patchpoint() callconv(.c) void;
extern fn demo_stack_call_target(a: i32, b: i32) callconv(.c) i32;
extern fn demo_stack_call_patchpoint() callconv(.c) void;
extern fn demo_prepatched_target() callconv(.c) i32;

fn signalReturn42(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    switch (builtin.cpu.arch) {
        .aarch64 => ctx.regs.named.x0 = 42,
        .x86_64 => ctx.regs.named.rax = 42,
        else => @compileError("api integration test only supports AArch64 and x86_64"),
    }
}

fn setAddInputs(ctx: *zighook.HookContext, a: u64, b: u64) void {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            ctx.regs.named.x0 = a;
            ctx.regs.named.x1 = b;
        },
        .x86_64 => {
            ctx.regs.named.rdi = a;
            ctx.regs.named.rsi = b;
        },
        else => @compileError("api integration test only supports AArch64 and x86_64"),
    }
}

fn signalReplay42(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    setAddInputs(ctx, 40, 2);
}

fn signalNoop(_: u64, _: *zighook.HookContext) callconv(.c) void {}

fn signalForceZeroFlag(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    switch (builtin.cpu.arch) {
        .x86_64 => ctx.flags |= 1 << 6,
        .aarch64 => {},
        else => @compileError("api integration test only supports AArch64 and x86_64"),
    }
}

fn signalSkip99(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    switch (builtin.cpu.arch) {
        .aarch64 => ctx.regs.named.x0 = 99,
        .x86_64 => ctx.regs.named.rax = 99,
        else => @compileError("api integration test only supports AArch64 and x86_64"),
    }
}

test "instrument replays the original instruction on both backends" {
    const patchpoint_addr: u64 = @intFromPtr(&demo_add_patchpoint);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.instrument(patchpoint_addr, signalReplay42);
    try std.testing.expectEqual(@as(i32, 42), demo_add_target(1, 2));
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(saved.slice().len > 0);
}

test "x86_64 instrument replays stack-pointer indirect calls" {
    if (builtin.cpu.arch != .x86_64) return;

    const patchpoint_addr: u64 = @intFromPtr(&demo_stack_call_patchpoint);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.instrument(patchpoint_addr, signalReplay42);
    try std.testing.expectEqual(@as(i32, 42), demo_stack_call_target(1, 2));
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(saved.slice().len > 0);
}

test "x86_64 instrument replays direct calls" {
    if (builtin.cpu.arch != .x86_64) return;

    const patchpoint_addr: u64 = @intFromPtr(&demo_direct_call_patchpoint);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.instrument(patchpoint_addr, signalReplay42);
    try std.testing.expectEqual(@as(i32, 42), demo_direct_call_target(1, 2));
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(saved.slice().len > 0);
}

test "x86_64 instrument replays direct jumps" {
    if (builtin.cpu.arch != .x86_64) return;

    const patchpoint_addr: u64 = @intFromPtr(&demo_direct_jump_patchpoint);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.instrument(patchpoint_addr, signalNoop);
    try std.testing.expectEqual(@as(i32, 7), demo_direct_jump_target());
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(saved.slice().len > 0);
}

test "x86_64 instrument replays RIP-relative indirect calls" {
    if (builtin.cpu.arch != .x86_64) return;

    const patchpoint_addr: u64 = @intFromPtr(&demo_rip_indirect_call_patchpoint);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.instrument(patchpoint_addr, signalReplay42);
    try std.testing.expectEqual(@as(i32, 42), demo_rip_indirect_call_target(1, 2));
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(saved.slice().len > 0);
}

test "x86_64 instrument replays RIP-relative indirect jumps" {
    if (builtin.cpu.arch != .x86_64) return;

    const patchpoint_addr: u64 = @intFromPtr(&demo_rip_indirect_jump_patchpoint);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.instrument(patchpoint_addr, signalNoop);
    try std.testing.expectEqual(@as(i32, 11), demo_rip_indirect_jump_target());
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(saved.slice().len > 0);
}

test "x86_64 instrument replays RIP-relative loads" {
    if (builtin.cpu.arch != .x86_64) return;

    const patchpoint_addr: u64 = @intFromPtr(&demo_rip_load_patchpoint);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.instrument(patchpoint_addr, signalNoop);
    try std.testing.expectEqual(@as(i32, 17), demo_rip_load_target());
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(saved.slice().len > 0);
}

test "x86_64 instrument replays conditional branches" {
    if (builtin.cpu.arch != .x86_64) return;

    const patchpoint_addr: u64 = @intFromPtr(&demo_conditional_branch_patchpoint);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.instrument(patchpoint_addr, signalForceZeroFlag);
    try std.testing.expectEqual(@as(i32, 42), demo_conditional_branch_target(1));
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(saved.slice().len > 0);
}

test "instrument_no_original skips the displaced instruction on both backends" {
    const patchpoint_addr: u64 = @intFromPtr(&demo_add_patchpoint);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.instrument_no_original(patchpoint_addr, signalSkip99);
    try std.testing.expectEqual(@as(i32, 99), demo_add_target(1, 2));
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(saved.slice().len > 0);
}

test "prepatched inline_hook registers and unregisters public runtime state" {
    const patchpoint_addr: u64 = @intFromPtr(&demo_prepatched_target);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.prepatched.inline_hook(patchpoint_addr, signalReturn42);
    try std.testing.expectEqual(@as(i32, 42), demo_prepatched_target());
    const saved = zighook.original_instruction(patchpoint_addr) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, if (builtin.cpu.arch == .aarch64) 4 else 1), saved.slice().len);
    try std.testing.expectEqual(if (builtin.cpu.arch == .aarch64) @as(?u32, 0xD420_0000) else null, zighook.original_opcode(patchpoint_addr));

    try zighook.unhook(patchpoint_addr);
    try std.testing.expectEqual(@as(?zighook.OriginalInstruction, null), zighook.original_instruction(patchpoint_addr));
    try std.testing.expectEqual(@as(?u32, null), zighook.original_opcode(patchpoint_addr));
}
