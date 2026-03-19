const builtin = @import("builtin");
const std = @import("std");

const zighook = @import("zighook");

extern fn demo_add_target(a: i32, b: i32) callconv(.c) i32;
extern fn demo_add_patchpoint() callconv(.c) void;
extern fn demo_direct_call_target(a: i32, b: i32) callconv(.c) i32;
extern fn demo_direct_call_patchpoint() callconv(.c) void;
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
