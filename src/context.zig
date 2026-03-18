//! Public register context layout exposed to hook callbacks.
//!
//! The layout intentionally mirrors the Rust version:
//! - `regs.x[i]` gives indexed access
//! - `regs.named.x0 ... x30` gives named access
//! - `sp`, `pc`, and `cpsr` are mapped directly from Darwin thread state
//!
//! On Apple Silicon macOS, this layout is binary-compatible with the Darwin
//! thread-state payload stored in `std.c.mcontext_t.ss`. That lets the signal
//! handler reinterpret the kernel-provided machine context without heap
//! allocation or per-register copies.

const std = @import("std");

/// Darwin thread-state type used by the currently supported backend.
const DarwinThreadState = @FieldType(std.c.mcontext_t, "ss");

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
    /// Padding required by the Darwin thread-state ABI.
    pad: u32,
};

// Refuse compilation if the public callback view ever drifts away from the
// Darwin kernel ABI we reinterpret in the signal handler.
comptime {
    std.debug.assert(@sizeOf(HookContext) == @sizeOf(DarwinThreadState));
    std.debug.assert(@alignOf(HookContext) == @alignOf(DarwinThreadState));
}

/// C-callable callback type used by all runtime hook entry points.
pub const InstrumentCallback = *const fn (address: u64, ctx: *HookContext) callconv(.c) void;

/// Reinterprets Darwin `thread_state` as the public hook context.
///
/// This is safe for the currently implemented backend because both layouts are
/// intentionally binary-compatible on macOS AArch64.
pub fn fromThreadState(thread_state: *DarwinThreadState) *HookContext {
    return @ptrCast(thread_state);
}
