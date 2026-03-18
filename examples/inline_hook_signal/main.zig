//! Hooks a function entry with a trap and returns directly from the callback.

const std = @import("std");
const zighook = @import("zighook");
const targets = @import("runtime_targets");

fn replaceInCallback(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    // `inline_hook(...)` returns to the caller if `ctx.pc` is left unchanged.
    ctx.regs.named.x0 = 42;
}

pub fn main() !void {
    const function_entry = targets.targetAddress();

    std.debug.print("before inline_hook: demo_add_target(6, 7) = {}\n", .{targets.add_target(6, 7)});
    _ = try zighook.inline_hook(function_entry, replaceInCallback);
    defer zighook.unhook(function_entry) catch {};

    std.debug.print("after inline_hook:  demo_add_target(6, 7) = {}\n", .{targets.add_target(6, 7)});
}
