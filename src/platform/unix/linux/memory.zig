//! Linux / Android executable-memory helpers.
//!
//! Android follows the Linux-family executable-page model closely enough that
//! the same `mprotect` and near-`mmap` strategy can back both platforms.

const std = @import("std");

const HookError = @import("../../../error.zig").HookError;
const TrampolineKind = @import("../../types.zig").TrampolineKind;

extern fn __clear_cache(start: [*]u8, end: [*]u8) void;

const ProtectRange = struct {
    start: usize,
    len: usize,
};

/// Writes raw machine code bytes into an executable page on Linux-family
/// systems.
///
/// The helper temporarily upgrades the containing pages to RWX, copies the new
/// bytes, flushes the instruction cache, and then restores RX protection.
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

pub fn flushInstructionCache(address: [*]u8, len: usize) void {
    __clear_cache(address, address + len);
}

/// Allocates a writable trampoline page.
///
/// For ordinary trampolines we accept any convenient mapping. For
/// RIP-relative x86_64 replay, however, the trampoline must stay within the
/// signed 32-bit displacement window of the displaced instruction so relocated
/// RIP-relative operands can still address the same absolute target.
pub fn allocateTrampolinePage(address_hint: u64, kind: TrampolineKind) HookError![]align(std.heap.page_size_min) u8 {
    return switch (kind) {
        .generic => fallbackAllocateTrampolinePage(address_hint),
        .rip_relative => allocateRipRelativeTrampolinePage(address_hint),
    };
}

/// Releases a trampoline page previously allocated by
/// `allocateTrampolinePage(...)`.
pub fn freeTrampolinePage(trampoline_pc: u64) void {
    if (trampoline_pc == 0) return;

    const page_size = std.heap.pageSize();
    const ptr: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(@as(usize, @intCast(trampoline_pc)));
    std.posix.munmap(ptr[0..page_size]);
}

fn fallbackAllocateTrampolinePage(address_hint: u64) HookError![]align(std.heap.page_size_min) u8 {
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

fn tryAllocatePageAt(candidate_addr: u64, page_size: usize) HookError!?[]align(std.heap.page_size_min) u8 {
    const candidate: ?[*]align(std.heap.page_size_min) u8 = @ptrFromInt(@as(usize, @intCast(candidate_addr)));
    return std.posix.mmap(
        candidate,
        page_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
            .FIXED_NOREPLACE = true,
        },
        -1,
        0,
    ) catch |err| switch (err) {
        error.MappingAlreadyExists => null,
        else => return error.TrampolineAllocationFailed,
    };
}

fn allocateRipRelativeTrampolinePage(address_hint: u64) HookError![]align(std.heap.page_size_min) u8 {
    const page_size = std.heap.pageSize();
    const page_mask = @as(u64, @intCast(page_size - 1));
    const base_addr = address_hint & ~page_mask;
    const max_distance = @as(u64, std.math.maxInt(i32)) & ~page_mask;
    const lower_bound = if (base_addr > max_distance) base_addr - max_distance else 0;
    const upper_bound = std.math.add(u64, base_addr, max_distance) catch (std.math.maxInt(u64) & ~page_mask);

    // Search symmetrically around the displaced instruction's page so the
    // first successful mapping is as close as possible. Staying nearby is not
    // just a nice-to-have: when we relocate a RIP-relative load/jump/call into
    // the trampoline we must still be able to encode the same absolute target
    // with a signed 32-bit displacement.
    var page_delta: u64 = 0;
    while (page_delta <= max_distance) : (page_delta += page_size) {
        const high_addr = std.math.add(u64, base_addr, page_delta) catch upper_bound + page_size;
        if (high_addr <= upper_bound) {
            if (try tryAllocatePageAt(high_addr, page_size)) |mapped| return mapped;
        }

        if (page_delta != 0 and base_addr >= lower_bound + page_delta) {
            const low_addr = base_addr - page_delta;
            if (try tryAllocatePageAt(low_addr, page_size)) |mapped| return mapped;
        }
    }

    // If the near search fails we fall back to an arbitrary mapping. Replay of
    // a RIP-relative instruction may still reject later if the relocated
    // displacement no longer fits in 32 bits, but this fallback keeps generic
    // trampoline users from failing just because the address space is crowded.
    return fallbackAllocateTrampolinePage(address_hint);
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
