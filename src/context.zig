//! Public register context layout exposed to hook callbacks.
//!
//! The Zig rewrite keeps this layout intentionally close to the Rust crate:
//! - `regs.x[i]` gives indexed access to x0..x30
//! - `regs.named.x0 ... x30` gives named access to the same registers
//! - `sp`, `pc`, and `cpsr` expose the architectural integer control state
//! - `fpregs.v[i]` exposes the raw 128-bit bits of `v0..v31`
//! - `fpregs.fpsr` / `fpregs.fpcr` expose the floating-point status/control
//!   registers
//!
//! Darwin splits this information across two machine-context payloads:
//! - `mcontext.ss` for general-purpose state
//! - `mcontext.ns` for NEON / FP state
//!
//! We therefore use an explicit remap and write-back step in the signal
//! handler instead of reinterpreting a single kernel struct in place. The copy
//! is small, stays on the stack, and keeps the public callback ABI independent
//! from the exact Darwin field layout.

const std = @import("std");

/// Darwin thread-state type used by the currently supported backend.
const DarwinThreadState = @FieldType(std.c.mcontext_t, "ss");
/// Darwin NEON / FP state type used by the currently supported backend.
const DarwinNeonState = @FieldType(std.c.mcontext_t, "ns");

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

/// Raw AArch64 SIMD / floating-point register bank.
///
/// Each `v[i]` element stores the architectural 128-bit `vN` register bits.
/// Callback code can reinterpret the low lanes as needed:
/// - low 32 bits: `sN`
/// - low 64 bits: `dN`
/// - full 128 bits: `qN`
pub const FpRegisters = extern struct {
    /// Raw bits of `v0..v31`.
    v: [32]u128,
    /// Floating-point status register.
    fpsr: u32,
    /// Floating-point control register.
    fpcr: u32,
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
    /// Raw SIMD / floating-point state (`v0..v31`, `fpsr`, `fpcr`).
    fpregs: FpRegisters,
};

// Keep the public callback layout aligned with the amount of state Darwin
// exposes through `ss + ns`, even though we copy it explicitly.
comptime {
    std.debug.assert(@sizeOf(XRegisters) == @sizeOf([31]u64));
    std.debug.assert(@sizeOf(FpRegisters) == @sizeOf(DarwinNeonState));
    std.debug.assert(@alignOf(FpRegisters) == @alignOf(DarwinNeonState));
    std.debug.assert(@sizeOf(HookContext) == @sizeOf(DarwinThreadState) + @sizeOf(DarwinNeonState));
    std.debug.assert(@alignOf(HookContext) == @alignOf(FpRegisters));
}

/// C-callable callback type used by all runtime hook entry points.
pub const InstrumentCallback = *const fn (address: u64, ctx: *HookContext) callconv(.c) void;

/// Copies Darwin machine context into the stable public callback layout.
///
/// The returned value is meant to live on the signal-handler stack. That keeps
/// callback code free to edit registers without directly mutating the Darwin
/// structs until zighook has decided that the trap really belongs to us.
pub fn captureMachineContext(mcontext: *const std.c.mcontext_t) HookContext {
    var ctx = std.mem.zeroes(HookContext);

    @memcpy(ctx.regs.x[0..29], mcontext.ss.regs[0..]);
    ctx.regs.x[29] = mcontext.ss.fp;
    ctx.regs.x[30] = mcontext.ss.lr;
    ctx.sp = mcontext.ss.sp;
    ctx.pc = mcontext.ss.pc;
    ctx.cpsr = mcontext.ss.cpsr;
    ctx.pad = mcontext.ss.__pad;

    @memcpy(ctx.fpregs.v[0..], mcontext.ns.q[0..]);
    ctx.fpregs.fpsr = mcontext.ns.fpsr;
    ctx.fpregs.fpcr = mcontext.ns.fpcr;
    return ctx;
}

/// Writes a callback-edited public context back into Darwin machine state.
///
/// This is called only after zighook has confirmed that the trap belongs to a
/// registered hook and the callback / replay path completed successfully.
pub fn writeBackMachineContext(mcontext: *std.c.mcontext_t, ctx: *const HookContext) void {
    @memcpy(mcontext.ss.regs[0..], ctx.regs.x[0..29]);
    mcontext.ss.fp = ctx.regs.x[29];
    mcontext.ss.lr = ctx.regs.x[30];
    mcontext.ss.sp = ctx.sp;
    mcontext.ss.pc = ctx.pc;
    mcontext.ss.cpsr = ctx.cpsr;
    mcontext.ss.__pad = ctx.pad;

    @memcpy(mcontext.ns.q[0..], ctx.fpregs.v[0..]);
    mcontext.ns.fpsr = ctx.fpregs.fpsr;
    mcontext.ns.fpcr = ctx.fpregs.fpcr;
}

test "Darwin machine context remap round-trips integer and FP state" {
    var mcontext = std.mem.zeroes(std.c.mcontext_t);

    for (mcontext.ss.regs[0..], 0..) |*reg, index| {
        reg.* = 0x1000 + index;
    }
    mcontext.ss.fp = 0x2000;
    mcontext.ss.lr = 0x3000;
    mcontext.ss.sp = 0x4000;
    mcontext.ss.pc = 0x5000;
    mcontext.ss.cpsr = 0x6000;
    mcontext.ss.__pad = 0x7000;

    for (mcontext.ns.q[0..], 0..) |*reg, index| {
        reg.* = (@as(u128, index) << 64) | (0xA0 + index);
    }
    mcontext.ns.fpsr = 0x8000;
    mcontext.ns.fpcr = 0x9000;

    var ctx = captureMachineContext(&mcontext);

    try std.testing.expectEqual(@as(u64, 0x1000), ctx.regs.x[0]);
    try std.testing.expectEqual(@as(u64, 0x101C), ctx.regs.x[28]);
    try std.testing.expectEqual(@as(u64, 0x2000), ctx.regs.x[29]);
    try std.testing.expectEqual(@as(u64, 0x3000), ctx.regs.x[30]);
    try std.testing.expectEqual(@as(u64, 0x4000), ctx.sp);
    try std.testing.expectEqual(@as(u64, 0x5000), ctx.pc);
    try std.testing.expectEqual(@as(u32, 0x6000), ctx.cpsr);
    try std.testing.expectEqual(@as(u32, 0x7000), ctx.pad);
    try std.testing.expectEqual((@as(u128, 31) << 64) | 0xBF, ctx.fpregs.v[31]);
    try std.testing.expectEqual(@as(u32, 0x8000), ctx.fpregs.fpsr);
    try std.testing.expectEqual(@as(u32, 0x9000), ctx.fpregs.fpcr);

    ctx.regs.x[0] = 0xDEAD;
    ctx.regs.x[29] = 0xBEEF;
    ctx.regs.x[30] = 0xCAFE;
    ctx.sp = 0x1111;
    ctx.pc = 0x2222;
    ctx.cpsr = 0x3333;
    ctx.pad = 0x4444;
    ctx.fpregs.v[0] = 0x1122_3344_5566_7788;
    ctx.fpregs.v[31] = (@as(u128, 0x9999_AAAA_BBBB_CCCC) << 64) | 0xDDDD_EEEE_FFFF_0000;
    ctx.fpregs.fpsr = 0x5555;
    ctx.fpregs.fpcr = 0x6666;

    writeBackMachineContext(&mcontext, &ctx);

    try std.testing.expectEqual(@as(u64, 0xDEAD), mcontext.ss.regs[0]);
    try std.testing.expectEqual(@as(u64, 0xBEEF), mcontext.ss.fp);
    try std.testing.expectEqual(@as(u64, 0xCAFE), mcontext.ss.lr);
    try std.testing.expectEqual(@as(u64, 0x1111), mcontext.ss.sp);
    try std.testing.expectEqual(@as(u64, 0x2222), mcontext.ss.pc);
    try std.testing.expectEqual(@as(u32, 0x3333), mcontext.ss.cpsr);
    try std.testing.expectEqual(@as(u32, 0x4444), mcontext.ss.__pad);
    try std.testing.expectEqual(@as(u128, 0x1122_3344_5566_7788), mcontext.ns.q[0]);
    try std.testing.expectEqual((@as(u128, 0x9999_AAAA_BBBB_CCCC) << 64) | 0xDDDD_EEEE_FFFF_0000, mcontext.ns.q[31]);
    try std.testing.expectEqual(@as(u32, 0x5555), mcontext.ns.fpsr);
    try std.testing.expectEqual(@as(u32, 0x6666), mcontext.ns.fpcr);
}
