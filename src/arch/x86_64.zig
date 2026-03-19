//! Public x86_64 backend facade.

const HookError = @import("../error.zig").HookError;
const memory = @import("../memory.zig");
const arch_constants = @import("x86_64/constants.zig");
const arch_context = @import("x86_64/context/root.zig");
const arch_instruction = @import("x86_64/instruction.zig");
const arch_trampoline = @import("x86_64/trampoline.zig");

pub const trap_opcode = arch_constants.int3_opcode;

pub const HookContext = arch_context.HookContext;
pub const InstrumentCallback = arch_context.InstrumentCallback;
pub const GpRegisters = arch_context.GpRegisters;
pub const GpRegistersNamed = arch_context.GpRegistersNamed;
pub const XRegisters = GpRegisters;
pub const XRegistersNamed = GpRegistersNamed;
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
    return false;
}

pub fn trapPatchBytes() []const u8 {
    return arch_constants.int3_bytes[0..];
}

pub fn validateAddress(address: u64) HookError!void {
    if (address == 0) return error.InvalidAddress;
}

pub fn instructionWidth(_: u64) HookError!u8 {
    return error.UnsupportedOperation;
}

pub fn isTrapInstruction(address: u64) HookError!bool {
    var opcode = [_]u8{0};
    try memory.readInto(address, opcode[0..]);
    return opcode[0] == arch_constants.int3_opcode;
}

pub fn trapAddress(ctx: *const HookContext) HookError!u64 {
    if (ctx.pc == 0) return error.InvalidAddress;
    return ctx.pc - 1;
}

pub fn normalizeTrapContext(ctx: *HookContext, address: u64) void {
    ctx.pc = address;
}

pub fn returnToCaller(ctx: *HookContext) HookError!void {
    var return_address_bytes = [_]u8{0} ** 8;
    try memory.readInto(ctx.sp, return_address_bytes[0..]);
    ctx.pc = std.mem.readInt(u64, return_address_bytes[0..], .little);
    ctx.sp += 8;
}

const std = @import("std");
