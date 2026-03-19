const builtin = @import("builtin");
const std = @import("std");

const zighook = @import("zighook");

extern fn demo_prepatched_target() callconv(.c) i32;

fn signalReturn42(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    switch (builtin.cpu.arch) {
        .aarch64 => ctx.regs.named.x0 = 42,
        .x86_64 => ctx.regs.named.rax = 42,
        else => @compileError("api integration test only supports AArch64 and x86_64"),
    }
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
