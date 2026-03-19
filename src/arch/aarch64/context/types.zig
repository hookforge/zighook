//! Shared public AArch64 callback context types.
//!
//! These definitions are OS-independent. Darwin and Linux/Android each provide
//! their own signal-context remapping layer that copies native kernel state
//! into this stable public layout.

const std = @import("std");

/// Named general-purpose register view for AArch64 callbacks.
pub const XRegistersNamed = extern struct {
    x0: u64,
    x1: u64,
    x2: u64,
    x3: u64,
    x4: u64,
    x5: u64,
    x6: u64,
    x7: u64,
    x8: u64,
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
    x29: u64,
    x30: u64,
};

/// Dual view over the 31 AArch64 general-purpose registers.
pub const XRegisters = extern union {
    x: [31]u64,
    named: XRegistersNamed,
};

/// Named 128-bit SIMD / floating-point register view.
///
/// The field names follow the architectural `vN` register bank because the
/// stored value is always the full 128-bit register contents.
pub const FpRegistersNamed = extern struct {
    v0: u128,
    v1: u128,
    v2: u128,
    v3: u128,
    v4: u128,
    v5: u128,
    v6: u128,
    v7: u128,
    v8: u128,
    v9: u128,
    v10: u128,
    v11: u128,
    v12: u128,
    v13: u128,
    v14: u128,
    v15: u128,
    v16: u128,
    v17: u128,
    v18: u128,
    v19: u128,
    v20: u128,
    v21: u128,
    v22: u128,
    v23: u128,
    v24: u128,
    v25: u128,
    v26: u128,
    v27: u128,
    v28: u128,
    v29: u128,
    v30: u128,
    v31: u128,
};

/// Dual view over the 32 AArch64 SIMD / floating-point registers.
pub const FpRegisters = extern union {
    v: [32]u128,
    named: FpRegistersNamed,
};

/// Mutable callback context passed to every instrumentation callback.
pub const HookContext = extern struct {
    /// General-purpose registers x0..x30.
    regs: XRegisters,
    /// Stack pointer at the time the trap was taken.
    sp: u64,
    /// Program counter that will be resumed after the callback returns.
    pc: u64,
    /// Current program status register.
    cpsr: u32,
    /// Backend-specific padding or auxiliary state.
    pad: u32,
    /// Raw SIMD / floating-point register bank (`v0..v31`).
    fpregs: FpRegisters,
    /// Floating-point status register.
    fpsr: u32,
    /// Floating-point control register.
    fpcr: u32,
};

// Keep the public callback layout stable across every OS backend.
comptime {
    std.debug.assert(@sizeOf(XRegisters) == @sizeOf([31]u64));
    std.debug.assert(@sizeOf(FpRegisters) == @sizeOf([32]u128));
    std.debug.assert(@alignOf(FpRegisters) == @alignOf([32]u128));
    std.debug.assert(@sizeOf(FpRegistersNamed) == @sizeOf([32]u128));
    std.debug.assert(@alignOf(HookContext) == @alignOf(FpRegisters));
}

/// C-callable callback type used by all runtime hook entry points.
pub const InstrumentCallback = *const fn (address: u64, ctx: *HookContext) callconv(.c) void;
