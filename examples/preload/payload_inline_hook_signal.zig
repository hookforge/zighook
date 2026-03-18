//! DYLD preload payload that installs `inline_hook(...)` on `target_add`.

const std = @import("std");
const zighook = @import("zighook");
const c = @cImport({
    @cInclude("dlfcn.h");
});

fn replaceInCallback(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    // Return a synthetic value directly to the caller.
    ctx.regs.named.x0 = 42;
}

pub export fn zighook_payload_init() callconv(.c) void {
    const symbol = c.dlsym(c.RTLD_DEFAULT, "target_add");
    if (symbol == null) {
        std.debug.print("zighook payload: target_add not found\n", .{});
        return;
    }

    _ = zighook.inline_hook(@intFromPtr(symbol.?), replaceInCallback) catch |err| {
        std.debug.print("zighook payload: inline_hook failed: {}\n", .{err});
    };
}
