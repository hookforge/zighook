//! Memory helpers shared by patching, trap handling, and trampoline creation.

const std = @import("std");

const HookError = @import("error.zig").HookError;
const platform_memory = @import("platform/memory_root.zig");

pub const TrampolineKind = platform_memory.TrampolineKind;

/// Reads arbitrary bytes from the current process image.
///
/// The current implementation assumes the caller is providing a readable
/// in-process address. This library is intentionally in-process only for now.
pub fn readInto(address: u64, out: []u8) HookError!void {
    if (address == 0 or out.len == 0) return error.InvalidAddress;

    const source: [*]const u8 = @ptrFromInt(@as(usize, @intCast(address)));
    @memcpy(out, source[0..out.len]);
}

/// Reads a single 32-bit instruction word.
pub fn readU32(address: u64) HookError!u32 {
    if (address == 0 or (address & 0b11) != 0) return error.InvalidAddress;

    const ptr: *const u32 = @ptrFromInt(@as(usize, @intCast(address)));
    return std.mem.littleToNative(u32, ptr.*);
}

/// Writes a 32-bit instruction word and returns the overwritten instruction.
pub fn patchU32(address: u64, new_opcode: u32) HookError!u32 {
    if (address == 0 or (address & 0b11) != 0) return error.InvalidAddress;

    const original = try readU32(address);
    const bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, new_opcode));
    try patchBytes(address, bytes[0..]);
    return original;
}

/// Writes raw bytes into executable memory.
///
/// This helper is responsible for:
/// - making the target page writable
/// - copying the replacement bytes
/// - flushing the instruction cache afterwards
/// - restoring executable protection
pub fn patchBytes(address: u64, bytes: []const u8) HookError!void {
    return platform_memory.patchBytes(address, bytes);
}

/// Flushes the instruction cache after writing code.
///
/// On self-modifying code paths this step is essential on AArch64, otherwise
/// the CPU may continue executing stale instructions fetched before the patch.
pub fn flushInstructionCache(address: [*]u8, len: usize) void {
    platform_memory.flushInstructionCache(address, len);
}

/// Allocates a writable page that an ISA backend can fill with trampoline code.
///
/// `address_hint` is the original instruction address. Some backends, such as
/// x86_64 RIP-relative replay, require the trampoline to live near that
/// address so relocated displacements remain encodable.
pub fn allocateTrampolinePage(address_hint: u64, kind: TrampolineKind) HookError![]align(std.heap.page_size_min) u8 {
    return platform_memory.allocateTrampolinePage(address_hint, kind);
}

/// Releases a trampoline page previously allocated through
/// `allocateTrampolinePage(...)`.
pub fn freeTrampolinePage(trampoline_pc: u64) void {
    platform_memory.freeTrampolinePage(trampoline_pc);
}
