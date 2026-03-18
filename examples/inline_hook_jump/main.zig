//! Hooks a function entry by writing a direct AArch64 branch / far jump patch.

const std = @import("std");
const zighook = @import("zighook");
const targets = @import("runtime_targets");

pub fn main() !void {
    // This demo detours the whole function entry to a separate replacement
    // function without relying on signal delivery after installation.
    const function_entry = targets.targetAddress();
    const replacement = targets.replacementAddress();

    std.debug.print("before inline_hook_jump: demo_add_target(6, 7) = {}\n", .{targets.add_target(6, 7)});
    _ = try zighook.inline_hook_jump(function_entry, replacement);
    defer zighook.unhook(function_entry) catch {};

    std.debug.print("after inline_hook_jump:  demo_add_target(6, 7) = {}\n", .{targets.add_target(6, 7)});
}
