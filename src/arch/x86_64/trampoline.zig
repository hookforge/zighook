//! x86_64 replay trampolines are not implemented yet.

const HookError = @import("../../error.zig").HookError;

pub fn createOriginalTrampoline(_: u64, _: []const u8, _: u8) HookError!u64 {
    return error.ReplayUnsupported;
}

pub fn freeOriginalTrampoline(_: u64) void {}
