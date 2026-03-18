//! Apple-specific memory utilities.
//!
//! The current backend uses Mach page protection APIs for text patching because
//! they work consistently for the in-process executable pages we need to modify.

const std = @import("std");

const HookError = @import("../error.zig").HookError;

const oscache = @cImport({
    @cInclude("libkern/OSCacheControl.h");
});

const ProtectRange = struct {
    start: usize,
    len: usize,
};

/// Writes machine code bytes into an executable region.
///
/// The caller is expected to:
/// - validate the address range
/// - preserve any original bytes it may need for later restoration
///
/// On Apple platforms we temporarily switch the page to writable copy-on-write
/// protection, patch the bytes in-place, invalidate the instruction cache, and
/// then restore RX permissions.
pub fn patchBytes(address: u64, bytes: []const u8) HookError!void {
    if (address == 0 or bytes.len == 0) return error.InvalidAddress;

    const address_usize: usize = @intCast(address);
    const protect_range = computeProtectRange(address_usize, bytes.len);

    const writable_prot = std.c.PROT.READ | std.c.PROT.WRITE | std.c.PROT.COPY;
    const restore_prot = std.c.PROT.READ | std.c.PROT.EXEC;

    const kr_writable = std.c.mach_vm_protect(
        std.c.mach_task_self(),
        protect_range.start,
        protect_range.len,
        0,
        writable_prot,
    );
    if (kr_writable != 0) return error.PageProtectionChangeFailed;

    const destination: [*]u8 = @ptrFromInt(address_usize);
    @memcpy(destination[0..bytes.len], bytes);
    flushInstructionCache(destination, bytes.len);

    const kr_executable = std.c.mach_vm_protect(
        std.c.mach_task_self(),
        protect_range.start,
        protect_range.len,
        0,
        restore_prot,
    );
    if (kr_executable != 0) return error.PageProtectionChangeFailed;
}

/// Flushes the instruction cache for a range that has just been written as data.
pub fn flushInstructionCache(address: [*]u8, len: usize) void {
    oscache.sys_icache_invalidate(address, len);
}

fn computeProtectRange(address: usize, len: usize) ProtectRange {
    const page_size = std.heap.pageSize();
    const start = std.mem.alignBackward(usize, address, page_size);
    const end = std.mem.alignForward(usize, address + len, page_size);
    return .{
        .start = start,
        .len = end - start,
    };
}

test "computeProtectRange spans exactly one page" {
    const page_size = std.heap.pageSize();
    const range = computeProtectRange(0x1003, 4);
    try std.testing.expectEqual(std.mem.alignBackward(usize, 0x1003, page_size), range.start);
    try std.testing.expectEqual(page_size, range.len);
}

test "computeProtectRange spans two pages when patch crosses a page boundary" {
    const page_size = std.heap.pageSize();
    // Place the address 2 bytes before the end of the first page so that a
    // small patch definitely crosses into the next page.
    const near_end = page_size - 2;
    const range = computeProtectRange(near_end, 8);
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(2 * page_size, range.len);
}

test "computeProtectRange starts exactly at a page boundary" {
    const page_size = std.heap.pageSize();
    const range = computeProtectRange(page_size, 4);
    try std.testing.expectEqual(page_size, range.start);
    try std.testing.expectEqual(page_size, range.len);
}
