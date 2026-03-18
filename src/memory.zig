//! Memory helpers shared by patching, trap handling, and trampoline creation.

const builtin = @import("builtin");
const std = @import("std");

const HookError = @import("error.zig").HookError;
const constants = @import("constants.zig");

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

/// Returns whether the 32-bit word encodes a `brk` instruction.
pub fn isBrk(opcode: u32) bool {
    return (opcode & constants.brk_mask) == (constants.brk_opcode & constants.brk_mask);
}

/// Returns the width of the instruction that starts at `address`.
///
/// The current backend only supports AArch64, so the answer is always 4 bytes.
pub fn instructionWidth(address: u64) HookError!u8 {
    if (address == 0 or (address & 0b11) != 0) return error.InvalidAddress;
    return 4;
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
    return switch (builtin.os.tag) {
        .macos => @import("platform/apple.zig").patchBytes(address, bytes),
        else => error.UnsupportedPlatform,
    };
}

/// Flushes the instruction cache after writing code.
///
/// On self-modifying code paths this step is essential on AArch64, otherwise
/// the CPU may continue executing stale instructions fetched before the patch.
pub fn flushInstructionCache(address: [*]u8, len: usize) void {
    switch (builtin.os.tag) {
        .macos => @import("platform/apple.zig").flushInstructionCache(address, len),
        else => {},
    }
}
