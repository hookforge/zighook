//! Traps a single instruction, mutates argument registers in the callback, and
//! then executes the original instruction through the trampoline backend.

const std = @import("std");
const zighook = @import("zighook");
const targets = @import("runtime_targets");

fn onHit(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    // Rewrite the input registers before the trapped `add` instruction is
    // replayed by zighook's trampoline.
    ctx.regs.named.x0 = 40;
    ctx.regs.named.x1 = 2;
}

pub fn main() !void {
    const patchpoint = targets.patchpointAddress();

    std.debug.print("before instrument: demo_add_target(3, 4) = {}\n", .{targets.add_target(3, 4)});
    _ = try zighook.instrument(patchpoint, onHit);
    defer zighook.unhook(patchpoint) catch {};

    std.debug.print("after instrument:  demo_add_target(3, 4) = {}\n", .{targets.add_target(3, 4)});
}
