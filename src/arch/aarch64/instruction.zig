//! AArch64 instruction helpers used by the macOS / Apple Silicon backend.
//!
//! This module analyzes and replays a strict whitelist of common PC-relative
//! instructions used by the trap-based backend.
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
//!
//! Notes on what is intentionally *not* in this whitelist:
//! - pair loads/stores such as `ldp` / `stp` are not PC-relative in AArch64;
//!   they use an explicit base register and therefore remain trampoline-safe
//! - ordinary register/immediate ALU instructions are also trampoline-safe for
//!   the same reason: moving the instruction does not change its meaning
//! - after `adrp` computes a page base, follow-up instructions like
//!   `add/ldr/str/ldp/stp [xN, ...]` use that register value rather than the
//!   architectural PC, so they do not need semantic replay planning

const std = @import("std");

const HookContext = @import("context/root.zig").HookContext;
const HookError = @import("../../error.zig").HookError;

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
/// - recognized forms are decoded through packed bitfield views so the code
///   mirrors the architectural instruction layout directly
/// - instructions like `ldp`, `stp`, and register-based `ldr/str` are not
///   special-cased here because they do not read the architectural PC
pub fn planReplay(address: u64, opcode: u32) HookError!ReplayPlan {
    if ((address & 0b11) != 0) return error.InvalidAddress;

    const adr_adrp: AdrAdrpInstruction = @bitCast(opcode);
    if (adr_adrp.fixed_op == adr_adrp_fixed_op) {
        return planAdrAdrp(address, adr_adrp);
    }

    const literal_load: LiteralLoadInstruction = @bitCast(opcode);
    if (literal_load.fixed_low == literal_load_fixed_low and
        literal_load.fixed_high == literal_load_fixed_high)
    {
        return planLiteralLoad(address, literal_load);
    }

    const unconditional_branch: UnconditionalImmediateBranchInstruction = @bitCast(opcode);
    if (unconditional_branch.fixed_op == unconditional_immediate_branch_fixed_op) {
        return planImmediateBranch(address, unconditional_branch);
    }

    const conditional_branch: ConditionalImmediateBranchInstruction = @bitCast(opcode);
    if (conditional_branch.fixed_zero == conditional_immediate_branch_fixed_zero and
        conditional_branch.fixed_op == conditional_immediate_branch_fixed_op)
    {
        return planConditionalBranch(address, conditional_branch);
    }

    const compare_and_branch: CompareAndBranchInstruction = @bitCast(opcode);
    if (compare_and_branch.fixed_op == compare_and_branch_fixed_op) {
        return planCompareAndBranch(address, compare_and_branch);
    }

    const test_bit_and_branch: TestBitAndBranchInstruction = @bitCast(opcode);
    if (test_bit_and_branch.fixed_op == test_bit_and_branch_fixed_op) {
        return planTestBitAndBranch(address, test_bit_and_branch);
    }

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

/// Packed decoder policy for replay-planned AArch64 instructions.
///
/// Every instruction family recognized by the replay planner is described as a
/// `packed struct(u32)` and decoded with `@bitCast`. This keeps the source
/// visually aligned with the Arm encoding diagrams.
///
/// Important endianness note:
/// - the packed structs below describe the logical 32-bit instruction word
/// - callers already materialize that word as a little-endian `u32`
/// - once the word exists as an integer, `@bitCast` exposes the architectural
///   bitfields directly
///
/// In other words, the code below is intentionally written as a teaching aid
/// as well as a decoder: the layout types are meant to show how the opcode is
/// actually partitioned in memory.
///
/// `ADR` / `ADRP` immediate-encoding class.
///
/// The architectural 21-bit immediate is split across two disjoint fields:
/// - `immhi` carries bits `[20:2]`
/// - `immlo` carries bits `[1:0]`
///
/// Field order intentionally follows the architectural bit numbering from low
/// to high bits:
/// - bits `[4:0]`   -> `rd`
/// - bits `[23:5]`  -> `immhi`
/// - bits `[28:24]` -> `fixed_op` (`0b10000` for this encoding class)
/// - bits `[30:29]` -> `immlo`
/// - bit  `[31]`    -> `op` (`0` = `ADR`, `1` = `ADRP`)
const AdrAdrpInstruction = packed struct(u32) {
    rd: u5,
    immhi: u19,
    fixed_op: u5,
    immlo: u2,
    op: u1,
};

/// `LDR (literal)`, `LDRSW (literal)`, and `PRFM (literal)` encoding class.
///
/// In Arm's diagrams this class is usually written as:
/// `opc | 011 | V | 00 | imm19 | Rt`
///
/// The packed view keeps that decomposition visible:
/// - `rt`      -> destination register / prefetch operand
/// - `imm19`   -> signed PC-relative immediate, scaled by 4
/// - `fixed_*` -> the opcode-class marker bits
/// - `v`       -> scalar/vector selector
/// - `opc`     -> operation/width selector within the class
const LiteralLoadInstruction = packed struct(u32) {
    rt: u5,
    imm19: u19,
    fixed_low: u2,
    v: u1,
    fixed_high: u3,
    opc: u2,
};

/// `B` / `BL` immediate branch encoding class.
///
/// Layout in low-to-high bit order:
/// - `imm26`    -> signed PC-relative immediate, scaled by 4
/// - `fixed_op` -> class tag `0b00101`
/// - `op`       -> `0` = `B`, `1` = `BL`
const UnconditionalImmediateBranchInstruction = packed struct(u32) {
    imm26: u26,
    fixed_op: u5,
    op: u1,
};

/// `B.<cond>` immediate branch encoding class.
///
/// Arm documents this form as `01010100 | imm19 | 0 | cond`.
/// The single zero bit at position 4 is architecturally significant, so it is
/// kept as an explicit field instead of disappearing into a mask.
const ConditionalImmediateBranchInstruction = packed struct(u32) {
    cond: u4,
    fixed_zero: u1,
    imm19: u19,
    fixed_op: u8,
};

/// `CBZ` / `CBNZ` encoding class.
///
/// Arm documents this form as `sf | 011010 | op | imm19 | Rt`.
/// - `sf` selects 32-bit vs 64-bit register width
/// - `op` selects zero-vs-nonzero branching
const CompareAndBranchInstruction = packed struct(u32) {
    rt: u5,
    imm19: u19,
    op: u1,
    fixed_op: u6,
    sf: u1,
};

/// `TBZ` / `TBNZ` encoding class.
///
/// Arm documents this form as `b5 | 011011 | op | b40 | imm14 | Rt`.
/// The tested bit index is physically split across:
/// - `b40` -> low five bits of the bit index
/// - `b5`  -> high one bit of the bit index
const TestBitAndBranchInstruction = packed struct(u32) {
    rt: u5,
    imm14: u14,
    b40: u5,
    op: u1,
    fixed_op: u6,
    b5: u1,
};

fn assertInstructionWordLayout(comptime T: type, comptime type_name: []const u8) void {
    if (@bitSizeOf(T) != 32) {
        @compileError(type_name ++ " must remain a 32-bit packed view.");
    }
}

comptime {
    assertInstructionWordLayout(AdrAdrpInstruction, "AdrAdrpInstruction");
    assertInstructionWordLayout(LiteralLoadInstruction, "LiteralLoadInstruction");
    assertInstructionWordLayout(
        UnconditionalImmediateBranchInstruction,
        "UnconditionalImmediateBranchInstruction",
    );
    assertInstructionWordLayout(
        ConditionalImmediateBranchInstruction,
        "ConditionalImmediateBranchInstruction",
    );
    assertInstructionWordLayout(CompareAndBranchInstruction, "CompareAndBranchInstruction");
    assertInstructionWordLayout(TestBitAndBranchInstruction, "TestBitAndBranchInstruction");
}

const adr_adrp_fixed_op: u5 = 0b10000;
const literal_load_fixed_low: u2 = 0b00;
const literal_load_fixed_high: u3 = 0b011;
const unconditional_immediate_branch_fixed_op: u5 = 0b00101;
const conditional_immediate_branch_fixed_zero: u1 = 0;
const conditional_immediate_branch_fixed_op: u8 = 0x54;
const compare_and_branch_fixed_op: u6 = 0b011010;
const test_bit_and_branch_fixed_op: u6 = 0b011011;

/// Decodes `ADR` / `ADRP` into a replay plan.
///
/// This decoder intentionally reconstructs the split immediate from the typed
/// bitfield view:
/// - `imm21 = (immhi << 2) | immlo`
/// - `op` chooses between `ADR` and `ADRP`
fn planAdrAdrp(address: u64, instr: AdrAdrpInstruction) HookError!ReplayPlan {
    const imm21: u21 = (@as(u21, instr.immhi) << 2) | @as(u21, instr.immlo);
    const signed_imm = signExtend(21, @as(u64, imm21));

    if (instr.op == 1) {
        const page_base = try addSignedOffset(address & ~@as(u64, 0xFFF), signed_imm << 12);
        return .{ .adrp = .{ .rd = instr.rd, .page_base = page_base } };
    }

    const absolute = try addSignedOffset(address, signed_imm);
    return .{ .adr = .{ .rd = instr.rd, .absolute = absolute } };
}

/// Decodes the AArch64 literal-load instruction family.
///
/// The interesting parts of this encoding are:
/// - `imm19`, which is sign-extended and scaled by 4
/// - `v`, which selects scalar GP loads vs FP/SIMD loads
/// - `opc`, which refines the width / operation inside that family
fn planLiteralLoad(address: u64, instr: LiteralLoadInstruction) HookError!ReplayPlan {
    const literal_address = try addSignedOffset(address, signExtend(19, @as(u64, instr.imm19)) << 2);

    if (instr.v == 1) {
        return switch (instr.opc) {
            0 => .{ .ldr_literal_s = .{ .rt = instr.rt, .literal_address = literal_address } },
            1 => .{ .ldr_literal_d = .{ .rt = instr.rt, .literal_address = literal_address } },
            2 => .{ .ldr_literal_q = .{ .rt = instr.rt, .literal_address = literal_address } },
            3 => error.ReplayUnsupported,
        };
    }

    return switch (instr.opc) {
        0 => .{ .ldr_literal_w = .{ .rt = instr.rt, .literal_address = literal_address } },
        1 => .{ .ldr_literal_x = .{ .rt = instr.rt, .literal_address = literal_address } },
        2 => .{ .ldrsw_literal = .{ .rt = instr.rt, .literal_address = literal_address } },
        3 => .{ .prfm_literal = .{ .literal_address = literal_address } },
    };
}

/// Decodes `B` / `BL`.
///
/// The 26-bit immediate is sign-extended and scaled by 4. The single `op` bit
/// chooses whether link register `x30` should be updated (`BL`) or not (`B`).
fn planImmediateBranch(
    address: u64,
    instr: UnconditionalImmediateBranchInstruction,
) HookError!ReplayPlan {
    const target = try addSignedOffset(address, signExtend(26, @as(u64, instr.imm26)) << 2);

    if (instr.op == 1) {
        return .{ .branch_with_link = .{ .target = target } };
    }
    return .{ .branch = .{ .target = target } };
}

/// Decodes `B.<cond>`.
///
/// The condition code is kept in a dedicated field instead of being extracted
/// from a mask so readers can see exactly where the low nibble lives inside
/// the instruction word.
fn planConditionalBranch(
    address: u64,
    instr: ConditionalImmediateBranchInstruction,
) HookError!ReplayPlan {
    const target = try addSignedOffset(address, signExtend(19, @as(u64, instr.imm19)) << 2);

    if (instr.cond == 0xF) return error.ReplayUnsupported;

    return .{ .conditional_branch = .{ .cond = instr.cond, .target = target } };
}

/// Decodes `CBZ` / `CBNZ`.
///
/// `sf` and `op` are intentionally preserved as named fields because together
/// they explain most of the instruction:
/// - `sf = 0` -> 32-bit register view
/// - `sf = 1` -> 64-bit register view
/// - `op = 0` -> branch if zero
/// - `op = 1` -> branch if nonzero
fn planCompareAndBranch(address: u64, instr: CompareAndBranchInstruction) HookError!ReplayPlan {
    const target = try addSignedOffset(address, signExtend(19, @as(u64, instr.imm19)) << 2);
    return .{
        .compare_and_branch = .{
            .rt = instr.rt,
            .target = target,
            .branch_on_zero = instr.op == 0,
            .is_64bit = instr.sf == 1,
        },
    };
}

/// Decodes `TBZ` / `TBNZ`.
///
/// The tested bit index is not contiguous in the instruction word. Keeping the
/// split representation (`b5` + `b40`) visible in the type makes the rebuild
/// rule obvious:
/// - `bit_index = (b5 << 5) | b40`
fn planTestBitAndBranch(
    address: u64,
    instr: TestBitAndBranchInstruction,
) HookError!ReplayPlan {
    const target = try addSignedOffset(address, signExtend(14, @as(u64, instr.imm14)) << 2);
    const bit_index: u6 = (@as(u6, instr.b5) << 5) | @as(u6, instr.b40);
    return .{
        .test_bit_and_branch = .{
            .rt = instr.rt,
            .bit_index = bit_index,
            .target = target,
            .branch_on_zero = instr.op == 0,
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
        ReplayPlan{ .prfm_literal = .{ .literal_address = 0x18 } },
        try planReplay(0x0, 0xD800_00C0),
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
            .compare_and_branch = .{
                .rt = 4,
                .target = 0x18,
                .branch_on_zero = false,
                .is_64bit = true,
            },
        },
        try planReplay(0x4, 0xB500_00A4),
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
    try std.testing.expectEqualDeep(
        ReplayPlan{
            .test_bit_and_branch = .{
                .rt = 6,
                .bit_index = 3,
                .target = 0x18,
                .branch_on_zero = false,
            },
        },
        try planReplay(0x8, 0x3718_0086),
    );
}

test "non PC-relative instructions stay trampoline-safe" {
    try std.testing.expectEqualDeep(
        ReplayPlan{ .trampoline = {} },
        try planReplay(0x0, 0xA940_0440),
    ); // ldp x0, x1, [x2]
    try std.testing.expectEqualDeep(
        ReplayPlan{ .trampoline = {} },
        try planReplay(0x4, 0xA900_10A3),
    ); // stp x3, x4, [x5]
    try std.testing.expectEqualDeep(
        ReplayPlan{ .trampoline = {} },
        try planReplay(0x8, 0x9104_8CE6),
    ); // add x6, x7, #0x123
}

test "packed instruction views match representative AArch64 encodings" {
    const adr: AdrAdrpInstruction = @bitCast(@as(u32, 0x1000_0020));
    try std.testing.expectEqual(@as(u5, 0), adr.rd);
    try std.testing.expectEqual(@as(u19, 1), adr.immhi);
    try std.testing.expectEqual(adr_adrp_fixed_op, adr.fixed_op);
    try std.testing.expectEqual(@as(u2, 0), adr.immlo);
    try std.testing.expectEqual(@as(u1, 0), adr.op);

    const adrp: AdrAdrpInstruction = @bitCast(@as(u32, 0x9000_0000));
    try std.testing.expectEqual(@as(u5, 0), adrp.rd);
    try std.testing.expectEqual(@as(u19, 0), adrp.immhi);
    try std.testing.expectEqual(adr_adrp_fixed_op, adrp.fixed_op);
    try std.testing.expectEqual(@as(u2, 0), adrp.immlo);
    try std.testing.expectEqual(@as(u1, 1), adrp.op);

    const ldr_literal_x: LiteralLoadInstruction = @bitCast(@as(u32, 0x5800_0181));
    try std.testing.expectEqual(@as(u5, 1), ldr_literal_x.rt);
    try std.testing.expectEqual(@as(u19, 12), ldr_literal_x.imm19);
    try std.testing.expectEqual(literal_load_fixed_low, ldr_literal_x.fixed_low);
    try std.testing.expectEqual(@as(u1, 0), ldr_literal_x.v);
    try std.testing.expectEqual(literal_load_fixed_high, ldr_literal_x.fixed_high);
    try std.testing.expectEqual(@as(u2, 1), ldr_literal_x.opc);

    const ldr_literal_q: LiteralLoadInstruction = @bitCast(@as(u32, 0x9C00_0040));
    try std.testing.expectEqual(@as(u5, 0), ldr_literal_q.rt);
    try std.testing.expectEqual(@as(u19, 2), ldr_literal_q.imm19);
    try std.testing.expectEqual(literal_load_fixed_low, ldr_literal_q.fixed_low);
    try std.testing.expectEqual(@as(u1, 1), ldr_literal_q.v);
    try std.testing.expectEqual(literal_load_fixed_high, ldr_literal_q.fixed_high);
    try std.testing.expectEqual(@as(u2, 2), ldr_literal_q.opc);

    const bl: UnconditionalImmediateBranchInstruction = @bitCast(@as(u32, 0x9400_0006));
    try std.testing.expectEqual(@as(u26, 6), bl.imm26);
    try std.testing.expectEqual(unconditional_immediate_branch_fixed_op, bl.fixed_op);
    try std.testing.expectEqual(@as(u1, 1), bl.op);

    const b_cond: ConditionalImmediateBranchInstruction = @bitCast(@as(u32, 0x5400_00A0));
    try std.testing.expectEqual(@as(u4, 0), b_cond.cond);
    try std.testing.expectEqual(conditional_immediate_branch_fixed_zero, b_cond.fixed_zero);
    try std.testing.expectEqual(@as(u19, 5), b_cond.imm19);
    try std.testing.expectEqual(conditional_immediate_branch_fixed_op, b_cond.fixed_op);

    const cbz: CompareAndBranchInstruction = @bitCast(@as(u32, 0xB400_0084));
    try std.testing.expectEqual(@as(u5, 4), cbz.rt);
    try std.testing.expectEqual(@as(u19, 4), cbz.imm19);
    try std.testing.expectEqual(@as(u1, 0), cbz.op);
    try std.testing.expectEqual(compare_and_branch_fixed_op, cbz.fixed_op);
    try std.testing.expectEqual(@as(u1, 1), cbz.sf);

    const tbz: TestBitAndBranchInstruction = @bitCast(@as(u32, 0x3618_0046));
    try std.testing.expectEqual(@as(u5, 6), tbz.rt);
    try std.testing.expectEqual(@as(u14, 2), tbz.imm14);
    try std.testing.expectEqual(@as(u5, 3), tbz.b40);
    try std.testing.expectEqual(@as(u1, 0), tbz.op);
    try std.testing.expectEqual(test_bit_and_branch_fixed_op, tbz.fixed_op);
    try std.testing.expectEqual(@as(u1, 0), tbz.b5);
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

test "FP literal replay updates q registers with the correct scalar semantics" {
    const literal_s: u32 = 0x3F80_0000;
    const literal_d: u64 = 0x4000_0000_0000_0000;
    const literal_q: u128 =
        (@as(u128, 0x0F1E_2D3C_4B5A_6978) << 64) | 0x8877_6655_4433_2211;

    var ctx = std.mem.zeroes(HookContext);
    ctx.fpregs.v[1] = std.math.maxInt(u128);
    ctx.fpregs.v[2] = std.math.maxInt(u128);
    ctx.fpregs.v[3] = std.math.maxInt(u128);

    try applyReplay(
        .{ .ldr_literal_s = .{ .rt = 1, .literal_address = @intFromPtr(&literal_s) } },
        0x1000,
        &ctx,
    );
    try std.testing.expectEqual(@as(u128, literal_s), ctx.fpregs.v[1]);
    try std.testing.expectEqual(@as(u64, 0x1004), ctx.pc);

    try applyReplay(
        .{ .ldr_literal_d = .{ .rt = 2, .literal_address = @intFromPtr(&literal_d) } },
        0x2000,
        &ctx,
    );
    try std.testing.expectEqual(@as(u128, literal_d), ctx.fpregs.v[2]);
    try std.testing.expectEqual(@as(u64, 0x2004), ctx.pc);

    try applyReplay(
        .{ .ldr_literal_q = .{ .rt = 3, .literal_address = @intFromPtr(&literal_q) } },
        0x3000,
        &ctx,
    );
    try std.testing.expectEqual(literal_q, ctx.fpregs.v[3]);
    try std.testing.expectEqual(@as(u64, 0x3004), ctx.pc);
}
