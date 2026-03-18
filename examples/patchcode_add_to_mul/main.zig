//! Patches a single `add` instruction into `mul` with a raw opcode.

const std = @import("std");
const zighook = @import("zighook");
const targets = @import("runtime_targets");

const mul_w0_w0_w1_opcode: u32 = 0x1B01_7C00;

pub fn main() !void {
    // This demo patches the single `add` instruction inside `demo_add_target`
    // into `mul w0, w0, w1`.
    const patchpoint = targets.patchpointAddress();

    std.debug.print("before patchcode: demo_add_target(6, 7) = {}\n", .{targets.add_target(6, 7)});
    _ = try zighook.patchcode(patchpoint, mul_w0_w0_w1_opcode);
    defer zighook.unhook(patchpoint) catch {};

    std.debug.print("after patchcode:  demo_add_target(6, 7) = {}\n", .{targets.add_target(6, 7)});
}
