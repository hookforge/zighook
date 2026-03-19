//! Public AArch64 backend facade.
//!
//! Architecture-specific pieces live under `arch/aarch64/` so future ISAs can
//! add their own sibling backends without mixing register layouts, instruction
//! decoders, or trampoline emitters into the shallow top-level module set.

const HookError = @import("../error.zig").HookError;
const memory = @import("../memory.zig");
const arch_constants = @import("aarch64/constants.zig");
const arch_context = @import("aarch64/context/root.zig");
const arch_instruction = @import("aarch64/instruction.zig");
const arch_trampoline = @import("aarch64/trampoline.zig");

pub const brk_opcode = arch_constants.brk_opcode;
pub const brk_mask = arch_constants.brk_mask;
pub const ldr_x16_literal_8 = arch_constants.ldr_x16_literal_8;
pub const br_x16 = arch_constants.br_x16;

pub const HookContext = arch_context.HookContext;
pub const InstrumentCallback = arch_context.InstrumentCallback;
pub const GpRegisters = arch_context.XRegisters;
pub const GpRegistersNamed = arch_context.XRegistersNamed;
pub const XRegisters = arch_context.XRegisters;
pub const XRegistersNamed = arch_context.XRegistersNamed;
pub const FpRegisters = arch_context.FpRegisters;
pub const FpRegistersNamed = arch_context.FpRegistersNamed;
pub const captureMachineContext = arch_context.captureMachineContext;
pub const writeBackMachineContext = arch_context.writeBackMachineContext;

pub const ReplayPlan = arch_instruction.ReplayPlan;
pub const planReplay = arch_instruction.planReplay;
pub const applyReplay = arch_instruction.applyReplay;

pub const createOriginalTrampoline = arch_trampoline.createOriginalTrampoline;
pub const freeOriginalTrampoline = arch_trampoline.freeOriginalTrampoline;

pub fn supportsPatchCode() bool {
    return true;
}

pub fn trapPatchBytes() []const u8 {
    return arch_constants.brk_bytes[0..];
}

pub fn validateAddress(address: u64) HookError!void {
    _ = try instructionWidth(address);
}

pub fn isTrapInstruction(address: u64) HookError!bool {
    return isBrk(try memory.readU32(address));
}

pub fn trapAddress(ctx: *const HookContext) HookError!u64 {
    try validateAddress(ctx.pc);
    return ctx.pc;
}

pub fn normalizeTrapContext(_: *HookContext, _: u64) void {}

pub fn returnToCaller(ctx: *HookContext) HookError!void {
    ctx.pc = ctx.regs.named.x30;
}

/// Returns whether the 32-bit word encodes a `brk` instruction.
pub fn isBrk(opcode: u32) bool {
    return (opcode & arch_constants.brk_mask) == (arch_constants.brk_opcode & arch_constants.brk_mask);
}

/// Returns the width of the instruction that starts at `address`.
///
/// The current backend only supports fixed-width AArch64 instructions, so the
/// answer is always 4 bytes once the address is validated.
pub fn instructionWidth(address: u64) HookError!u8 {
    if (address == 0 or (address & 0b11) != 0) return error.InvalidAddress;
    return 4;
}
