//! AArch64 instruction helpers used by the macOS / Apple Silicon backend.
//!
//! This module now has two responsibilities:
//! - build the machine-code patches used by direct jump detours
//! - analyze and replay a strict whitelist of common PC-relative instructions
//!
//! Why the replay planner exists:
//! - `instrument(...)` patches one instruction with `brk`
//! - after the callback returns, zighook may need to execute the displaced
//!   original instruction
//! - ordinary instructions can be replayed from a tiny trampoline
//! - PC-relative instructions cannot always be replayed from a trampoline,
//!   because moving the instruction to a different address changes its meaning
//!
//! To keep the current backend predictable, the planner is intentionally
//! strict:
//! - common PC-relative instruction families are recognized explicitly
//! - supported families are replayed by semantic emulation in the signal path
//! - unsupported families fail at install time with `ReplayUnsupported`
//!
//! The currently supported PC-relative whitelist is:
//! - `adr`
//! - `adrp`
//! - `ldr (literal)` into `wN`
//! - `ldr (literal)` into `xN`
//! - `ldr (literal)` into `sN`
//! - `ldr (literal)` into `dN`
//! - `ldr (literal)` into `qN`
//! - `ldrsw (literal)`
//! - `prfm (literal)` (treated as architecturally ignorable hint)
//! - `b`
//! - `bl`
//! - `b.cond`
//! - `cbz` / `cbnz`
//! - `tbz` / `tbnz`

const std = @import("std");

const HookContext = @import("../context.zig").HookContext;
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

/// Replay plan chosen for a displaced AArch64 instruction.
///
/// `instrument(...)` stores one of these plans in the runtime hook slot. When
/// the trap fires and the callback leaves `ctx.pc` untouched, the signal
/// handler executes the plan:
/// - `.trampoline` means "jump to the trampoline and run the real opcode there"
/// - `.adr`, `.bl`, `.ldr_literal_x`, ... mean "emulate the opcode directly"
///
/// The plan is computed at hook-install time so the signal hot path does not
/// need to decode instruction bits on every trap.
pub const ReplayPlan = union(enum) {
    /// No execute-original path is needed. This is used by
    /// `instrument_no_original(...)` and `inline_hook(...)`.
    skip: void,

    /// The displaced opcode is safe to replay from the out-of-line trampoline.
    trampoline: void,

    /// `adr xd, label`
    adr: struct {
        rd: u5,
        absolute: u64,
    },

    /// `adrp xd, label`
    adrp: struct {
        rd: u5,
        page_base: u64,
    },

    /// `ldr wt, label`
    ldr_literal_w: struct {
        rt: u5,
        literal_address: u64,
    },

    /// `ldr xt, label`
    ldr_literal_x: struct {
        rt: u5,
        literal_address: u64,
    },

    /// `ldr st, label`
    ///
    /// Replay writes the low 32 bits of `vT` and clears the remaining 96 bits,
    /// matching the architectural scalar-register view used by hardware.
    ldr_literal_s: struct {
        rt: u5,
        literal_address: u64,
    },

    /// `ldr dt, label`
    ///
    /// Replay writes the low 64 bits of `vT` and clears the high 64 bits.
    ldr_literal_d: struct {
        rt: u5,
        literal_address: u64,
    },

    /// `ldr qt, label`
    ldr_literal_q: struct {
        rt: u5,
        literal_address: u64,
    },

    /// `ldrsw xt, label`
    ldrsw_literal: struct {
        rt: u5,
        literal_address: u64,
    },

    /// `prfm <op>, label`
    ///
    /// `prfm` is only a hint. Architecturally, dropping it has no functional
    /// effect on the visible register/memory state, so replay is just "advance
    /// to the next instruction".
    prfm_literal: struct {
        literal_address: u64,
    },

    /// `b label`
    branch: struct {
        target: u64,
    },

    /// `bl label`
    branch_with_link: struct {
        target: u64,
    },

    /// `b.<cond> label`
    conditional_branch: struct {
        cond: u4,
        target: u64,
    },

    /// `cbz` / `cbnz`
    compare_and_branch: struct {
        rt: u5,
        target: u64,
        branch_on_zero: bool,
        is_64bit: bool,
    },

    /// `tbz` / `tbnz`
    test_bit_and_branch: struct {
        rt: u5,
        bit_index: u6,
        target: u64,
        branch_on_zero: bool,
    },

    /// Returns whether this replay plan needs a trampoline allocation.
    pub fn requiresTrampoline(plan: ReplayPlan) bool {
        return switch (plan) {
            .trampoline => true,
            else => false,
        };
    }
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

/// Computes a replay plan for the 32-bit AArch64 opcode currently located at
/// `address`.
///
/// The planner is intentionally centered around PC-relative behavior:
/// - if the opcode is not one of the recognized PC-relative forms, it is
///   considered trampoline-safe
/// - if the opcode is one of the supported PC-relative forms, a semantic
///   emulation plan is returned
/// - if the opcode is a recognized PC-relative form that the current callback
///   context cannot replay correctly, installation fails
pub fn planReplay(address: u64, opcode: u32) HookError!ReplayPlan {
    if ((address & 0b11) != 0) return error.InvalidAddress;

    if (isAdrAdrp(opcode)) return planAdrAdrp(address, opcode);
    if (isLiteralLoad(opcode)) return planLiteralLoad(address, opcode);
    if (isUnconditionalImmediateBranch(opcode)) return planImmediateBranch(address, opcode);
    if (isConditionalImmediateBranch(opcode)) return planConditionalBranch(address, opcode);
    if (isCompareAndBranch(opcode)) return planCompareAndBranch(address, opcode);
    if (isTestBitAndBranch(opcode)) return planTestBitAndBranch(address, opcode);

    return .{ .trampoline = {} };
}

/// Applies a previously computed replay plan to `ctx`.
///
/// The caller is expected to run the user callback first. If the callback left
/// `ctx.pc` unchanged and the runtime policy says "execute original", this
/// function is responsible for making architectural state look as though the
/// original instruction had just executed at its original address.
pub fn applyReplay(plan: ReplayPlan, address: u64, ctx: *HookContext) HookError!void {
    const next_pc = address + 4;

    switch (plan) {
        .skip => {
            ctx.pc = next_pc;
        },
        .trampoline => return error.ReplayUnsupported,
        .adr => |op| {
            writeXRegister(ctx, op.rd, op.absolute);
            ctx.pc = next_pc;
        },
        .adrp => |op| {
            writeXRegister(ctx, op.rd, op.page_base);
            ctx.pc = next_pc;
        },
        .ldr_literal_w => |op| {
            var buffer: [4]u8 = undefined;
            readMemoryInto(op.literal_address, buffer[0..]);
            writeWRegister(ctx, op.rt, std.mem.readInt(u32, buffer[0..], .little));
            ctx.pc = next_pc;
        },
        .ldr_literal_x => |op| {
            var buffer: [8]u8 = undefined;
            readMemoryInto(op.literal_address, buffer[0..]);
            writeXRegister(ctx, op.rt, std.mem.readInt(u64, buffer[0..], .little));
            ctx.pc = next_pc;
        },
        .ldr_literal_s => |op| {
            var buffer: [4]u8 = undefined;
            readMemoryInto(op.literal_address, buffer[0..]);
            writeSRegister(ctx, op.rt, std.mem.readInt(u32, buffer[0..], .little));
            ctx.pc = next_pc;
        },
        .ldr_literal_d => |op| {
            var buffer: [8]u8 = undefined;
            readMemoryInto(op.literal_address, buffer[0..]);
            writeDRegister(ctx, op.rt, std.mem.readInt(u64, buffer[0..], .little));
            ctx.pc = next_pc;
        },
        .ldr_literal_q => |op| {
            var buffer: [16]u8 = undefined;
            readMemoryInto(op.literal_address, buffer[0..]);
            writeQRegister(ctx, op.rt, std.mem.readInt(u128, buffer[0..], .little));
            ctx.pc = next_pc;
        },
        .ldrsw_literal => |op| {
            var buffer: [4]u8 = undefined;
            readMemoryInto(op.literal_address, buffer[0..]);
            const signed = std.mem.readInt(i32, buffer[0..], .little);
            writeXRegister(ctx, op.rt, @bitCast(@as(i64, signed)));
            ctx.pc = next_pc;
        },
        .prfm_literal => {
            ctx.pc = next_pc;
        },
        .branch => |op| {
            ctx.pc = op.target;
        },
        .branch_with_link => |op| {
            writeXRegister(ctx, 30, next_pc);
            ctx.pc = op.target;
        },
        .conditional_branch => |op| {
            ctx.pc = if (conditionHolds(ctx.cpsr, op.cond)) op.target else next_pc;
        },
        .compare_and_branch => |op| {
            const register_value = readXRegister(ctx, op.rt);
            const is_zero = if (op.is_64bit)
                register_value == 0
            else
                @as(u32, @truncate(register_value)) == 0;

            const should_branch = if (op.branch_on_zero) is_zero else !is_zero;
            ctx.pc = if (should_branch) op.target else next_pc;
        },
        .test_bit_and_branch => |op| {
            const register_value = readXRegister(ctx, op.rt);
            const bit_is_zero = ((register_value >> op.bit_index) & 1) == 0;
            const should_branch = if (op.branch_on_zero) bit_is_zero else !bit_is_zero;
            ctx.pc = if (should_branch) op.target else next_pc;
        },
    }
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

fn isAdrAdrp(opcode: u32) bool {
    return (opcode & 0x1F00_0000) == 0x1000_0000;
}

fn isLiteralLoad(opcode: u32) bool {
    return (opcode & 0x3B00_0000) == 0x1800_0000;
}

fn isUnconditionalImmediateBranch(opcode: u32) bool {
    return (opcode & 0x7C00_0000) == 0x1400_0000;
}

fn isConditionalImmediateBranch(opcode: u32) bool {
    return (opcode & 0xFF00_0010) == 0x5400_0000;
}

fn isCompareAndBranch(opcode: u32) bool {
    return (opcode & 0x7E00_0000) == 0x3400_0000;
}

fn isTestBitAndBranch(opcode: u32) bool {
    return (opcode & 0x7E00_0000) == 0x3600_0000;
}

fn planAdrAdrp(address: u64, opcode: u32) HookError!ReplayPlan {
    const rd: u5 = @truncate(opcode);
    const immlo: u64 = (opcode >> 29) & 0x3;
    const immhi: u64 = (opcode >> 5) & 0x7F_FFFF;
    const imm21 = (immhi << 2) | immlo;
    const signed_imm = signExtend(21, imm21);

    if ((opcode & 0x8000_0000) != 0) {
        const page_base = try addSignedOffset(address & ~@as(u64, 0xFFF), signed_imm << 12);
        return .{ .adrp = .{ .rd = rd, .page_base = page_base } };
    }

    const absolute = try addSignedOffset(address, signed_imm);
    return .{ .adr = .{ .rd = rd, .absolute = absolute } };
}

fn planLiteralLoad(address: u64, opcode: u32) HookError!ReplayPlan {
    const is_vector = ((opcode >> 26) & 0x1) != 0;
    const imm19: u64 = (opcode >> 5) & 0x7F_FFFF;
    const literal_address = try addSignedOffset(address, signExtend(19, imm19) << 2);
    const rt: u5 = @truncate(opcode);
    const opc: u2 = @truncate(opcode >> 30);

    if (is_vector) {
        return switch (opc) {
            0 => .{ .ldr_literal_s = .{ .rt = rt, .literal_address = literal_address } },
            1 => .{ .ldr_literal_d = .{ .rt = rt, .literal_address = literal_address } },
            2 => .{ .ldr_literal_q = .{ .rt = rt, .literal_address = literal_address } },
            3 => error.ReplayUnsupported,
        };
    }

    return switch (opc) {
        0 => .{ .ldr_literal_w = .{ .rt = rt, .literal_address = literal_address } },
        1 => .{ .ldr_literal_x = .{ .rt = rt, .literal_address = literal_address } },
        2 => .{ .ldrsw_literal = .{ .rt = rt, .literal_address = literal_address } },
        3 => .{ .prfm_literal = .{ .literal_address = literal_address } },
    };
}

fn planImmediateBranch(address: u64, opcode: u32) HookError!ReplayPlan {
    const imm26: u64 = opcode & 0x03FF_FFFF;
    const target = try addSignedOffset(address, signExtend(26, imm26) << 2);

    if ((opcode & 0x8000_0000) != 0) {
        return .{ .branch_with_link = .{ .target = target } };
    }
    return .{ .branch = .{ .target = target } };
}

fn planConditionalBranch(address: u64, opcode: u32) HookError!ReplayPlan {
    const imm19: u64 = (opcode >> 5) & 0x7F_FFFF;
    const target = try addSignedOffset(address, signExtend(19, imm19) << 2);
    const cond: u4 = @truncate(opcode);

    if (cond == 0xF) return error.ReplayUnsupported;

    return .{ .conditional_branch = .{ .cond = cond, .target = target } };
}

fn planCompareAndBranch(address: u64, opcode: u32) HookError!ReplayPlan {
    const imm19: u64 = (opcode >> 5) & 0x7F_FFFF;
    const target = try addSignedOffset(address, signExtend(19, imm19) << 2);
    const rt: u5 = @truncate(opcode);
    const branch_on_zero = ((opcode >> 24) & 0x1) == 0;
    const is_64bit = ((opcode >> 31) & 0x1) != 0;

    return .{
        .compare_and_branch = .{
            .rt = rt,
            .target = target,
            .branch_on_zero = branch_on_zero,
            .is_64bit = is_64bit,
        },
    };
}

fn planTestBitAndBranch(address: u64, opcode: u32) HookError!ReplayPlan {
    const imm14: u64 = (opcode >> 5) & 0x3FFF;
    const target = try addSignedOffset(address, signExtend(14, imm14) << 2);
    const rt: u5 = @truncate(opcode);
    const branch_on_zero = ((opcode >> 24) & 0x1) == 0;
    const bit_low5: u6 = @truncate((opcode >> 19) & 0x1F);
    const bit_high1: u6 = @truncate((opcode >> 31) & 0x1);
    const bit_index = (bit_high1 << 5) | bit_low5;

    return .{
        .test_bit_and_branch = .{
            .rt = rt,
            .bit_index = bit_index,
            .target = target,
            .branch_on_zero = branch_on_zero,
        },
    };
}

fn addSignedOffset(base: u64, offset: i64) HookError!u64 {
    const sum = @as(i128, @intCast(base)) + @as(i128, offset);
    if (sum < 0 or sum > std.math.maxInt(u64)) return error.InvalidAddress;
    return @intCast(sum);
}

fn signExtend(comptime bits: u7, raw: u64) i64 {
    const shift = 64 - bits;
    return @as(i64, @bitCast(raw << shift)) >> shift;
}

fn readMemoryInto(address: u64, out: []u8) void {
    const source: [*]const u8 = @ptrFromInt(@as(usize, @intCast(address)));
    @memcpy(out, source[0..out.len]);
}

fn readXRegister(ctx: *HookContext, reg: u5) u64 {
    if (reg == 31) return 0;
    return ctx.regs.x[reg];
}

fn writeXRegister(ctx: *HookContext, reg: u5, value: u64) void {
    if (reg == 31) return;
    ctx.regs.x[reg] = value;
}

fn writeWRegister(ctx: *HookContext, reg: u5, value: u32) void {
    writeXRegister(ctx, reg, value);
}

fn writeSRegister(ctx: *HookContext, reg: u5, value: u32) void {
    // Scalar FP literal loads still target the architectural `vN` register
    // bank. On Apple Silicon, `ldr sN, literal` clears the upper 96 bits of
    // `qN`, so model it as a full 128-bit register overwrite with the 32-bit
    // payload in the low lane.
    ctx.fpregs.v[reg] = value;
}

fn writeDRegister(ctx: *HookContext, reg: u5, value: u64) void {
    // `ldr dN, literal` writes the low 64 bits of `vN` and clears the upper
    // half of `qN`.
    ctx.fpregs.v[reg] = value;
}

fn writeQRegister(ctx: *HookContext, reg: u5, value: u128) void {
    ctx.fpregs.v[reg] = value;
}

fn conditionHolds(cpsr: u32, cond: u4) bool {
    const n = ((cpsr >> 31) & 1) != 0;
    const z = ((cpsr >> 30) & 1) != 0;
    const c = ((cpsr >> 29) & 1) != 0;
    const v = ((cpsr >> 28) & 1) != 0;

    return switch (cond) {
        0x0 => z,
        0x1 => !z,
        0x2 => c,
        0x3 => !c,
        0x4 => n,
        0x5 => !n,
        0x6 => v,
        0x7 => !v,
        0x8 => c and !z,
        0x9 => !c or z,
        0xA => n == v,
        0xB => n != v,
        0xC => !z and (n == v),
        0xD => z or (n != v),
        0xE => true,
        0xF => false,
    };
}

test "near branch encoding stays within imm26" {
    const from: u64 = 0x1000;
    const to: u64 = 0x1010;
    try std.testing.expectEqual(@as(u32, 0x1400_0004), try encodeBranch(from, to));
}

test "replay planner recognizes common PC-relative families" {
    try std.testing.expectEqualDeep(
        ReplayPlan{ .adr = .{ .rd = 0, .absolute = 0x1004 } },
        try planReplay(0x1000, 0x1000_0020),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .adrp = .{ .rd = 0, .page_base = 0x1000 } },
        try planReplay(0x1234, 0x9000_0000),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .ldr_literal_x = .{ .rt = 1, .literal_address = 0x38 } },
        try planReplay(0x8, 0x5800_0181),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .ldr_literal_w = .{ .rt = 2, .literal_address = 0x34 } },
        try planReplay(0xC, 0x1800_0142),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .ldr_literal_s = .{ .rt = 0, .literal_address = 0x8 } },
        try planReplay(0x0, 0x1C00_0040),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .ldr_literal_d = .{ .rt = 0, .literal_address = 0x14 } },
        try planReplay(0xC, 0x5C00_0040),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .ldr_literal_q = .{ .rt = 0, .literal_address = 0x24 } },
        try planReplay(0x1C, 0x9C00_0040),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .ldrsw_literal = .{ .rt = 3, .literal_address = 0x34 } },
        try planReplay(0x10, 0x9800_0123),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .branch = .{ .target = 0x30 } },
        try planReplay(0x14, 0x1400_0007),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .branch_with_link = .{ .target = 0x30 } },
        try planReplay(0x18, 0x9400_0006),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{ .conditional_branch = .{ .cond = 0, .target = 0x30 } },
        try planReplay(0x1C, 0x5400_00A0),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{
            .compare_and_branch = .{
                .rt = 4,
                .target = 0x30,
                .branch_on_zero = true,
                .is_64bit = true,
            },
        },
        try planReplay(0x20, 0xB400_0084),
    );
    try std.testing.expectEqualDeep(
        ReplayPlan{
            .test_bit_and_branch = .{
                .rt = 6,
                .bit_index = 3,
                .target = 0x30,
                .branch_on_zero = true,
            },
        },
        try planReplay(0x28, 0x3618_0046),
    );
}

test "condition evaluator matches common NZCV predicates" {
    const z_set: u32 = 1 << 30;
    const c_set: u32 = 1 << 29;
    const n_set: u32 = 1 << 31;
    const v_set: u32 = 1 << 28;

    try std.testing.expect(conditionHolds(z_set, 0x0));
    try std.testing.expect(!conditionHolds(0, 0x0));
    try std.testing.expect(conditionHolds(c_set, 0x2));
    try std.testing.expect(conditionHolds(n_set | v_set, 0xA));
    try std.testing.expect(conditionHolds(n_set, 0xB));
    try std.testing.expect(conditionHolds(0, 0xE));
}
