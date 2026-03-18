//! Traps a single instruction, replaces the result in the callback, and skips
//! the original instruction by default.

const std = @import("std");
const zighook = @import("zighook");
const targets = @import("runtime_targets");

fn replaceLogic(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    // Replace the instruction result outright; `instrument_no_original(...)`
    // will skip the trapped `add` instruction afterwards.
    ctx.regs.named.x0 = 99;
}

pub fn main() !void {
    const patchpoint = targets.patchpointAddress();

    std.debug.print("before instrument_no_original: demo_add_target(3, 4) = {}\n", .{targets.add_target(3, 4)});
    _ = try zighook.instrument_no_original(patchpoint, replaceLogic);
    defer zighook.unhook(patchpoint) catch {};

    std.debug.print("after instrument_no_original:  demo_add_target(3, 4) = {}\n", .{targets.add_target(3, 4)});
}
