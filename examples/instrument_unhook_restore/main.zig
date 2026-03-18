//! Demonstrates that `unhook` restores the runtime-patched code bytes.

const std = @import("std");
const zighook = @import("zighook");
const targets = @import("runtime_targets");

fn onHit(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    // The hook forces a synthetic result while installed.
    ctx.regs.named.x0 = 123;
}

pub fn main() !void {
    const patchpoint = targets.patchpointAddress();

    std.debug.print("before install: demo_add_target(3, 4) = {}\n", .{targets.add_target(3, 4)});
    _ = try zighook.instrument_no_original(patchpoint, onHit);

    std.debug.print("while hooked:   demo_add_target(3, 4) = {}\n", .{targets.add_target(3, 4)});
    try zighook.unhook(patchpoint);

    std.debug.print("after unhook:   demo_add_target(3, 4) = {}\n", .{targets.add_target(3, 4)});
}
