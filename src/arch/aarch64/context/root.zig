//! Public AArch64 callback context facade.
//!
//! Files under `context/` are split by responsibility:
//! - `types.zig`: stable public register/context layout
//! - `darwin.zig`: Darwin signal-frame bridge
//! - `linux.zig`: Linux / Android signal-frame bridge
//! - `root.zig`: backend selector and public re-exports
//!
//! The register layout itself is OS-independent, but the signal-frame bridge is
//! platform-specific:
//! - Darwin (`macOS`, `iOS`) remaps from `mcontext.ss + mcontext.ns`
//! - Linux-family targets (`Linux`, `Android`) remap from `ucontext_t` plus
//!   AArch64 extension records stored in the reserved signal-frame area

const builtin = @import("builtin");

const types = @import("types.zig");
const backend = switch (builtin.os.tag) {
    .macos, .ios => @import("darwin.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("AArch64 signal-context remapping is only implemented for Darwin and Linux-family targets."),
};

pub const XRegistersNamed = types.XRegistersNamed;
pub const XRegisters = types.XRegisters;
pub const FpRegistersNamed = types.FpRegistersNamed;
pub const FpRegisters = types.FpRegisters;
pub const HookContext = types.HookContext;
pub const InstrumentCallback = types.InstrumentCallback;

/// Copies the current OS signal frame into the stable public callback layout.
pub const captureMachineContext = backend.captureMachineContext;

/// Writes a callback-edited public context back into the current OS signal frame.
pub const writeBackMachineContext = backend.writeBackMachineContext;
