//! DYLD preload payload that detours `target_add` to a replacement function.

const std = @import("std");
const zighook = @import("zighook");
const c = @cImport({
    @cInclude("dlfcn.h");
});

fn replacement(a: i32, b: i32) callconv(.c) i32 {
    return a * b;
}

pub export fn zighook_payload_init() callconv(.c) void {
    const symbol = c.dlsym(c.RTLD_DEFAULT, "target_add");
    if (symbol == null) {
        std.debug.print("zighook payload: target_add not found\n", .{});
        return;
    }

    _ = zighook.inline_hook_jump(@intFromPtr(symbol.?), @intFromPtr(&replacement)) catch |err| {
        std.debug.print("zighook payload: inline_hook_jump failed: {}\n", .{err});
    };
}
