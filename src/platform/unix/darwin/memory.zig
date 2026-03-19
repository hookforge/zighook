//! Darwin-family executable-memory helpers.

const std = @import("std");

const HookError = @import("../../../error.zig").HookError;
const TrampolineKind = @import("../../types.zig").TrampolineKind;

extern fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

const ProtectRange = struct {
    start: usize,
    len: usize,
};

/// Writes raw machine code bytes into an executable page on Darwin-family
/// systems.
///
/// Darwin enforces code-signing-aware page permission transitions through
/// Mach VM APIs, so patching uses `mach_vm_protect` instead of plain POSIX
/// `mprotect`.
pub fn patchBytes(address: u64, bytes: []const u8) HookError!void {
    if (address == 0 or bytes.len == 0) return error.InvalidAddress;

    const address_usize: usize = @intCast(address);
    const protect_range = computeProtectRange(address_usize, bytes.len);

    const writable_prot = std.c.PROT.READ | std.c.PROT.WRITE | std.c.PROT.COPY;
    const restore_prot = std.c.PROT.READ | std.c.PROT.EXEC;

    // The page range may span more than one page when the patch straddles a
    // boundary, so compute and protect the entire enclosing region up front.
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

pub fn flushInstructionCache(address: [*]u8, len: usize) void {
    sys_icache_invalidate(address, len);
}

/// Allocates a writable trampoline page.
///
/// Darwin does not currently expose a special locality policy here. The
/// caller still provides `address_hint` so future backends can choose a closer
/// mapping strategy without changing the higher-level API.
pub fn allocateTrampolinePage(address_hint: u64, _: TrampolineKind) HookError![]align(std.heap.page_size_min) u8 {
    const page_size = std.heap.pageSize();
    const page_mask = @as(u64, @intCast(page_size - 1));
    const hint_addr = address_hint & ~page_mask;
    const hint: ?[*]align(std.heap.page_size_min) u8 = if (hint_addr != 0)
        @ptrFromInt(@as(usize, @intCast(hint_addr)))
    else
        null;

    return std.posix.mmap(
        hint,
        page_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
        },
        -1,
        0,
    ) catch return error.TrampolineAllocationFailed;
}

/// Releases a trampoline page previously allocated by
/// `allocateTrampolinePage(...)`.
pub fn freeTrampolinePage(trampoline_pc: u64) void {
    if (trampoline_pc == 0) return;

    const page_size = std.heap.pageSize();
    const ptr: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(@as(usize, @intCast(trampoline_pc)));
    std.posix.munmap(ptr[0..page_size]);
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
