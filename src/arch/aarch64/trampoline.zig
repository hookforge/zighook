//! Original-instruction trampoline support.
//!
//! `instrument(...)` needs a tiny scratch executable region that:
//! 1. replays the original instruction
//! 2. jumps back to the instruction that follows the trap patch
//!
//! For the first backend slice this is implemented only for AArch64 macOS.

const std = @import("std");

const HookError = @import("../../error.zig").HookError;
const constants = @import("constants.zig");
const memory = @import("../../memory.zig");

/// Allocates an RX trampoline that replays `original_bytes` and continues at
/// `address + step_len`.
///
/// Emitted AArch64 sequence:
/// 1. original 32-bit instruction
/// 2. `ldr x16, #8`
/// 3. `br x16`
/// 4. 64-bit literal containing the resume PC
pub fn createOriginalTrampoline(address: u64, original_bytes: []const u8, step_len: u8) HookError!u64 {
    if (original_bytes.len != 4 or step_len != 4) return error.InvalidAddress;

    const page_size = std.heap.pageSize();
    const mapped = std.posix.mmap(
        null,
        page_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
        },
        -1,
        0,
    ) catch return error.TrampolineAllocationFailed;
    errdefer std.posix.munmap(mapped);

    const next_pc = address + step_len;
    const original_opcode = std.mem.readInt(u32, original_bytes[0..4], .little);
    const original_opcode_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, original_opcode));
    const ldr_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, constants.ldr_x16_literal_8));
    const br_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, constants.br_x16));
    const literal_bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, next_pc));

    // The trampoline is deliberately tiny and position-independent. Replaying
    // a single instruction is enough for the current AArch64 backend because
    // every trap point we install replaces exactly one 4-byte instruction.
    @memcpy(mapped[0..4], original_opcode_bytes[0..]);
    @memcpy(mapped[4..8], ldr_bytes[0..]);
    @memcpy(mapped[8..12], br_bytes[0..]);
    @memcpy(mapped[12..20], literal_bytes[0..]);

    memory.flushInstructionCache(mapped.ptr, 20);

    std.posix.mprotect(mapped, std.posix.PROT.READ | std.posix.PROT.EXEC) catch {
        return error.TrampolineProtectFailed;
    };

    return @intFromPtr(mapped.ptr);
}

/// Releases a trampoline previously returned by `createOriginalTrampoline`.
pub fn freeOriginalTrampoline(trampoline_pc: u64) void {
    if (trampoline_pc == 0) return;

    const page_size = std.heap.pageSize();
    const ptr: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(@as(usize, @intCast(trampoline_pc)));
    std.posix.munmap(ptr[0..page_size]);
}
