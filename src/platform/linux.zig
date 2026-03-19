//! Linux / Android executable-memory patch helpers.
//!
//! Android follows the Linux AArch64 kernel ABI and the same `mprotect` +
//! instruction-cache invalidation strategy works for sidecar `.so` payloads.

const std = @import("std");

const HookError = @import("../error.zig").HookError;

extern fn __clear_cache(start: [*]u8, end: [*]u8) void;

const ProtectRange = struct {
    start: usize,
    len: usize,
};

/// Writes machine code bytes into an executable region.
pub fn patchBytes(address: u64, bytes: []const u8) HookError!void {
    if (address == 0 or bytes.len == 0) return error.InvalidAddress;

    const address_usize: usize = @intCast(address);
    const protect_range = computeProtectRange(address_usize, bytes.len);

    const writable_prot = std.c.PROT.READ | std.c.PROT.WRITE | std.c.PROT.EXEC;
    const restore_prot = std.c.PROT.READ | std.c.PROT.EXEC;

    const start_ptr: *align(std.heap.page_size_min) anyopaque = @ptrFromInt(protect_range.start);
    if (std.c.mprotect(start_ptr, protect_range.len, writable_prot) != 0) {
        return error.PageProtectionChangeFailed;
    }

    const destination: [*]u8 = @ptrFromInt(address_usize);
    @memcpy(destination[0..bytes.len], bytes);
    flushInstructionCache(destination, bytes.len);

    if (std.c.mprotect(start_ptr, protect_range.len, restore_prot) != 0) {
        return error.PageProtectionChangeFailed;
    }
}

/// Flushes the instruction cache for a range that has just been written as data.
pub fn flushInstructionCache(address: [*]u8, len: usize) void {
    __clear_cache(address, address + len);
}

fn computeProtectRange(address: usize, len: usize) ProtectRange {
    const page_size = std.heap.pageSize();
    const start = address & ~(page_size - 1);
    const end_inclusive = address + len - 1;
    const end_page = end_inclusive & ~(page_size - 1);

    return .{
        .start = start,
        .len = (end_page + page_size) - start,
    };
}

test "computeProtectRange spans exactly one page" {
    const page_size = std.heap.pageSize();
    const range = computeProtectRange(0x1003, 4);
    try std.testing.expectEqual(@as(usize, 0x1003) & ~(page_size - 1), range.start);
    try std.testing.expectEqual(page_size, range.len);
}
