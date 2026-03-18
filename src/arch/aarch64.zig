//! AArch64 instruction helpers used by the first backend slice.
//!
//! At the moment this module focuses on:
//! - encoding near unconditional branches (`b`)
//! - building the far-jump sequence used by `inline_hook_jump`
//! - exposing a few instruction opcodes reused by the trampoline backend

const std = @import("std");

const HookError = @import("../error.zig").HookError;
const constants = @import("../constants.zig");

/// The largest inline detour patch emitted by the current backend.
///
/// The far-jump form is:
/// - `ldr x16, #8`
/// - `br  x16`
/// - embedded 64-bit absolute target literal
pub const max_patch_len = 16;

/// Encoded inline detour bytes and their effective length.
pub const InlineJumpPatch = struct {
    bytes: [max_patch_len]u8 = [_]u8{0} ** max_patch_len,
    len: usize,
};

/// Encodes `b <target>` at `from_address`.
///
/// The current implementation is intentionally strict:
/// - both addresses must be 4-byte aligned
/// - the branch must fit in AArch64 `imm26`
/// - the offset is computed relative to the branch instruction itself
pub fn encodeBranch(from_address: u64, to_address: u64) HookError!u32 {
    if ((from_address & 0b11) != 0 or (to_address & 0b11) != 0) {
        return error.InvalidAddress;
    }

    const offset = @as(i128, @intCast(to_address)) - @as(i128, @intCast(from_address));
    if ((offset & 0b11) != 0) return error.BranchOutOfRange;

    const imm26 = offset >> 2;
    const min = -(@as(i128, 1) << 25);
    const max = (@as(i128, 1) << 25) - 1;
    if (imm26 < min or imm26 > max) return error.BranchOutOfRange;

    const imm26_bits: u32 = @intCast(@as(u128, @bitCast(imm26)) & 0x03FF_FFFF);
    return 0x1400_0000 | imm26_bits;
}

/// Builds the patch bytes used by `inline_hook_jump`.
///
/// Strategy:
/// - prefer a compact 4-byte near `b`
/// - fall back to a 16-byte absolute jump sequence when the destination is not
///   reachable by `imm26`
pub fn makeInlineJumpPatch(from_address: u64, to_address: u64) HookError!InlineJumpPatch {
    const near_branch = encodeBranch(from_address, to_address) catch |err| switch (err) {
        error.BranchOutOfRange => return makeAbsoluteJumpPatch(to_address),
        else => return err,
    };

    var patch = InlineJumpPatch{ .len = 4 };
    const branch_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, near_branch));
    @memcpy(patch.bytes[0..4], branch_bytes[0..]);
    return patch;
}

fn makeAbsoluteJumpPatch(to_address: u64) InlineJumpPatch {
    var patch = InlineJumpPatch{ .len = max_patch_len };
    const ldr_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, constants.ldr_x16_literal_8));
    const br_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, constants.br_x16));
    const literal_bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, to_address));

    @memcpy(patch.bytes[0..4], ldr_bytes[0..]);
    @memcpy(patch.bytes[4..8], br_bytes[0..]);
    @memcpy(patch.bytes[8..16], literal_bytes[0..]);
    return patch;
}

test "near branch encoding stays within imm26" {
    const from: u64 = 0x1000;
    const to: u64 = 0x1010;
    try std.testing.expectEqual(@as(u32, 0x1400_0004), try encodeBranch(from, to));
}
