//! Darwin AArch64 signal-context remapping.
//!
//! macOS and iOS expose general-purpose and NEON / FP state as two separate
//! machine-context payloads (`ss` + `ns`). This module copies those fields into
//! the stable public `HookContext` layout and writes them back after callback
//! dispatch completes.

const std = @import("std");

const types = @import("types.zig");

/// Darwin thread-state type used by the currently supported backend.
const DarwinThreadState = @FieldType(std.c.mcontext_t, "ss");
/// Darwin NEON / FP state type used by the currently supported backend.
const DarwinNeonState = @FieldType(std.c.mcontext_t, "ns");

/// ABI-equivalent view of the Darwin NEON payload used for layout checks.
const FpStateLayout = extern struct {
    fpregs: types.FpRegisters,
    fpsr: u32,
    fpcr: u32,
};

fn captureFromMcontext(mcontext: *const std.c.mcontext_t) types.HookContext {
    var ctx = std.mem.zeroes(types.HookContext);

    @memcpy(ctx.regs.x[0..29], mcontext.ss.regs[0..]);
    ctx.regs.x[29] = mcontext.ss.fp;
    ctx.regs.x[30] = mcontext.ss.lr;
    ctx.sp = mcontext.ss.sp;
    ctx.pc = mcontext.ss.pc;
    ctx.cpsr = mcontext.ss.cpsr;
    ctx.pad = mcontext.ss.__pad;

    @memcpy(ctx.fpregs.v[0..], mcontext.ns.q[0..]);
    ctx.fpsr = mcontext.ns.fpsr;
    ctx.fpcr = mcontext.ns.fpcr;
    return ctx;
}

fn writeBackToMcontext(mcontext: *std.c.mcontext_t, ctx: *const types.HookContext) void {
    @memcpy(mcontext.ss.regs[0..], ctx.regs.x[0..29]);
    mcontext.ss.fp = ctx.regs.x[29];
    mcontext.ss.lr = ctx.regs.x[30];
    mcontext.ss.sp = ctx.sp;
    mcontext.ss.pc = ctx.pc;
    mcontext.ss.cpsr = ctx.cpsr;
    mcontext.ss.__pad = ctx.pad;

    @memcpy(mcontext.ns.q[0..], ctx.fpregs.v[0..]);
    mcontext.ns.fpsr = ctx.fpsr;
    mcontext.ns.fpcr = ctx.fpcr;
}

/// Copies a Darwin signal frame into the stable public callback layout.
pub fn captureMachineContext(uctx_opaque: ?*anyopaque) ?types.HookContext {
    if (uctx_opaque == null) return null;

    // Darwin may hand signal handlers a context pointer that is not naturally
    // aligned for Zig's `ucontext_t` view. Follow the same defensive pattern
    // used by `std.debug` and treat the outer frame as byte-aligned.
    const uctx: *align(1) std.c.ucontext_t = @ptrCast(uctx_opaque.?);
    return captureFromMcontext(uctx.mcontext);
}

/// Writes a callback-edited public context back into a Darwin signal frame.
pub fn writeBackMachineContext(uctx_opaque: ?*anyopaque, ctx: *const types.HookContext) bool {
    if (uctx_opaque == null) return false;

    const uctx: *align(1) std.c.ucontext_t = @ptrCast(uctx_opaque.?);
    writeBackToMcontext(uctx.mcontext, ctx);
    return true;
}

// Keep the public callback layout aligned with the amount of state Darwin
// exposes through `ss + ns`, even though we copy it explicitly.
comptime {
    std.debug.assert(@sizeOf(FpStateLayout) == @sizeOf(DarwinNeonState));
    std.debug.assert(@alignOf(FpStateLayout) == @alignOf(DarwinNeonState));
    std.debug.assert(@sizeOf(types.HookContext) == @sizeOf(DarwinThreadState) + @sizeOf(DarwinNeonState));
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

    var ctx = captureFromMcontext(&mcontext);

    try std.testing.expectEqual(@as(u64, 0x1000), ctx.regs.x[0]);
    try std.testing.expectEqual(@as(u64, 0x101C), ctx.regs.x[28]);
    try std.testing.expectEqual(@as(u64, 0x2000), ctx.regs.x[29]);
    try std.testing.expectEqual(@as(u64, 0x3000), ctx.regs.x[30]);
    try std.testing.expectEqual(@as(u64, 0x4000), ctx.sp);
    try std.testing.expectEqual(@as(u64, 0x5000), ctx.pc);
    try std.testing.expectEqual(@as(u32, 0x6000), ctx.cpsr);
    try std.testing.expectEqual(@as(u32, 0x7000), ctx.pad);
    try std.testing.expectEqual((@as(u128, 31) << 64) | 0xBF, ctx.fpregs.v[31]);
    try std.testing.expectEqual((@as(u128, 31) << 64) | 0xBF, ctx.fpregs.named.v31);
    try std.testing.expectEqual(@as(u32, 0x8000), ctx.fpsr);
    try std.testing.expectEqual(@as(u32, 0x9000), ctx.fpcr);

    ctx.regs.x[0] = 0xDEAD;
    ctx.regs.x[29] = 0xBEEF;
    ctx.regs.x[30] = 0xCAFE;
    ctx.sp = 0x1111;
    ctx.pc = 0x2222;
    ctx.cpsr = 0x3333;
    ctx.pad = 0x4444;
    ctx.fpregs.named.v0 = 0x1122_3344_5566_7788;
    ctx.fpregs.named.v31 = (@as(u128, 0x9999_AAAA_BBBB_CCCC) << 64) | 0xDDDD_EEEE_FFFF_0000;
    ctx.fpsr = 0x5555;
    ctx.fpcr = 0x6666;

    writeBackToMcontext(&mcontext, &ctx);

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
