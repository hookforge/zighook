const std = @import("std");

const zighook = @import("zighook");

extern fn demo_prepatched_target() callconv(.c) i32;

fn signalReturn42(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    ctx.regs.named.x0 = 42;
}

test "prepatched inline_hook registers and unregisters public runtime state" {
    const patchpoint_addr: u64 = @intFromPtr(&demo_prepatched_target);

    defer zighook.unhook(patchpoint_addr) catch {};

    _ = try zighook.prepatched.inline_hook(patchpoint_addr, signalReturn42);
    try std.testing.expectEqual(@as(i32, 42), demo_prepatched_target());
    try std.testing.expect(zighook.original_opcode(patchpoint_addr) != null);

    try zighook.unhook(patchpoint_addr);
    try std.testing.expectEqual(@as(?u32, null), zighook.original_opcode(patchpoint_addr));
}
