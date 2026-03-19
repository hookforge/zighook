//! Public AArch64 backend facade.
//!
//! Architecture-specific pieces live under `arch/aarch64/` so future ISAs can
//! add their own sibling backends without mixing register layouts, instruction
//! decoders, or trampoline emitters into the shallow top-level module set.

const HookError = @import("../error.zig").HookError;
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
