//! Public x86_64 context facade.

const builtin = @import("builtin");
const types = @import("types.zig");

const backend = switch (builtin.os.tag) {
    .macos => @import("darwin.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("x86_64 context remapping is currently implemented for macOS and Linux only."),
};

pub const HookContext = types.HookContext;
pub const InstrumentCallback = types.InstrumentCallback;
pub const GpRegisters = types.GpRegisters;
pub const GpRegistersNamed = types.GpRegistersNamed;
pub const FpRegisters = types.FpRegisters;
pub const FpRegistersNamed = types.FpRegistersNamed;

pub const captureMachineContext = backend.captureMachineContext;
pub const writeBackMachineContext = backend.writeBackMachineContext;
