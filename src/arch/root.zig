//! Compile-time architecture selector.

const builtin = @import("builtin");

const current = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64.zig"),
    .x86_64 => @import("x86_64.zig"),
    else => @compileError("zighook currently implements AArch64 and x86_64 backends only."),
};

pub const HookContext = current.HookContext;
pub const InstrumentCallback = current.InstrumentCallback;
pub const GpRegisters = current.GpRegisters;
pub const GpRegistersNamed = current.GpRegistersNamed;
pub const XRegisters = current.XRegisters;
pub const XRegistersNamed = current.XRegistersNamed;
pub const FpRegisters = current.FpRegisters;
pub const FpRegistersNamed = current.FpRegistersNamed;
pub const captureMachineContext = current.captureMachineContext;
pub const writeBackMachineContext = current.writeBackMachineContext;
pub const ReplayPlan = current.ReplayPlan;
pub const planReplay = current.planReplay;
pub const applyReplay = current.applyReplay;
pub const createOriginalTrampoline = current.createOriginalTrampoline;
pub const freeOriginalTrampoline = current.freeOriginalTrampoline;
pub const supportsPatchCode = current.supportsPatchCode;
pub const trapPatchBytes = current.trapPatchBytes;
pub const validateAddress = current.validateAddress;
pub const isTrapInstruction = current.isTrapInstruction;
pub const trapAddress = current.trapAddress;
pub const normalizeTrapContext = current.normalizeTrapContext;
pub const returnToCaller = current.returnToCaller;
pub const instructionWidth = current.instructionWidth;
