//! Darwin x86_64 signal-context remapping.

const std = @import("std");

const types = @import("types.zig");

const DarwinFloatState = @FieldType(std.c.mcontext_t, "fs");

fn readU128(bytes: []const u8) u128 {
    return std.mem.readInt(u128, bytes[0..16], .little);
}

fn writeU128(bytes: []u8, value: u128) void {
    std.mem.writeInt(u128, bytes[0..16], value, .little);
}

fn captureFromMcontext(mcontext: *const std.c.mcontext_t) types.HookContext {
    var ctx = std.mem.zeroes(types.HookContext);

    ctx.regs.named.rax = mcontext.ss.rax;
    ctx.regs.named.rbx = mcontext.ss.rbx;
    ctx.regs.named.rcx = mcontext.ss.rcx;
    ctx.regs.named.rdx = mcontext.ss.rdx;
    ctx.regs.named.rdi = mcontext.ss.rdi;
    ctx.regs.named.rsi = mcontext.ss.rsi;
    ctx.regs.named.rbp = mcontext.ss.rbp;
    ctx.regs.named.r8 = mcontext.ss.r8;
    ctx.regs.named.r9 = mcontext.ss.r9;
    ctx.regs.named.r10 = mcontext.ss.r10;
    ctx.regs.named.r11 = mcontext.ss.r11;
    ctx.regs.named.r12 = mcontext.ss.r12;
    ctx.regs.named.r13 = mcontext.ss.r13;
    ctx.regs.named.r14 = mcontext.ss.r14;
    ctx.regs.named.r15 = mcontext.ss.r15;
    ctx.sp = mcontext.ss.rsp;
    ctx.pc = mcontext.ss.rip;
    ctx.flags = mcontext.ss.rflags;
    ctx.cs = mcontext.ss.cs;
    ctx.gs = mcontext.ss.gs;
    ctx.fs = mcontext.ss.fs;
    ctx.ss = 0;

    for (mcontext.fs.xmm, 0..) |xmm, index| {
        ctx.fpregs.xmm[index] = readU128(xmm[0..]);
    }
    ctx.mxcsr = mcontext.fs.mxcsr;
    return ctx;
}

fn writeBackToMcontext(mcontext: *std.c.mcontext_t, ctx: *const types.HookContext) void {
    mcontext.ss.rax = ctx.regs.named.rax;
    mcontext.ss.rbx = ctx.regs.named.rbx;
    mcontext.ss.rcx = ctx.regs.named.rcx;
    mcontext.ss.rdx = ctx.regs.named.rdx;
    mcontext.ss.rdi = ctx.regs.named.rdi;
    mcontext.ss.rsi = ctx.regs.named.rsi;
    mcontext.ss.rbp = ctx.regs.named.rbp;
    mcontext.ss.rsp = ctx.sp;
    mcontext.ss.r8 = ctx.regs.named.r8;
    mcontext.ss.r9 = ctx.regs.named.r9;
    mcontext.ss.r10 = ctx.regs.named.r10;
    mcontext.ss.r11 = ctx.regs.named.r11;
    mcontext.ss.r12 = ctx.regs.named.r12;
    mcontext.ss.r13 = ctx.regs.named.r13;
    mcontext.ss.r14 = ctx.regs.named.r14;
    mcontext.ss.r15 = ctx.regs.named.r15;
    mcontext.ss.rip = ctx.pc;
    mcontext.ss.rflags = ctx.flags;
    mcontext.ss.cs = ctx.cs;
    mcontext.ss.gs = ctx.gs;
    mcontext.ss.fs = ctx.fs;

    for (ctx.fpregs.xmm, 0..) |xmm, index| {
        writeU128(mcontext.fs.xmm[index][0..], xmm);
    }
    mcontext.fs.mxcsr = ctx.mxcsr;
}

pub fn captureMachineContext(uctx_opaque: ?*anyopaque) ?types.HookContext {
    if (uctx_opaque == null) return null;

    const uctx: *align(1) std.c.ucontext_t = @ptrCast(uctx_opaque.?);
    return captureFromMcontext(uctx.mcontext);
}

pub fn writeBackMachineContext(uctx_opaque: ?*anyopaque, ctx: *const types.HookContext) bool {
    if (uctx_opaque == null) return false;

    const uctx: *align(1) std.c.ucontext_t = @ptrCast(uctx_opaque.?);
    writeBackToMcontext(uctx.mcontext, ctx);
    return true;
}

comptime {
    std.debug.assert(@sizeOf(@FieldType(DarwinFloatState, "xmm")) == @sizeOf([16][16]u8));
}

test "Darwin x86_64 machine context remaps GPRs and XMM state" {
    var mcontext = std.mem.zeroes(std.c.mcontext_t);

    mcontext.ss.rax = 1;
    mcontext.ss.rbx = 2;
    mcontext.ss.rcx = 3;
    mcontext.ss.rdx = 4;
    mcontext.ss.rdi = 5;
    mcontext.ss.rsi = 6;
    mcontext.ss.rbp = 7;
    mcontext.ss.rsp = 8;
    mcontext.ss.r8 = 9;
    mcontext.ss.r9 = 10;
    mcontext.ss.r10 = 11;
    mcontext.ss.r11 = 12;
    mcontext.ss.r12 = 13;
    mcontext.ss.r13 = 14;
    mcontext.ss.r14 = 15;
    mcontext.ss.r15 = 16;
    mcontext.ss.rip = 17;
    mcontext.ss.rflags = 18;
    mcontext.ss.cs = 19;
    mcontext.ss.fs = 20;
    mcontext.ss.gs = 21;
    writeU128(mcontext.fs.xmm[0][0..], 0x1122_3344_5566_7788);
    writeU128(mcontext.fs.xmm[15][0..], (@as(u128, 0xAAAA_BBBB_CCCC_DDDD) << 64) | 0xEEEE_FFFF_0000_1111);
    mcontext.fs.mxcsr = 0x2222;

    var ctx = captureFromMcontext(&mcontext);

    try std.testing.expectEqual(@as(u64, 1), ctx.regs.named.rax);
    try std.testing.expectEqual(@as(u64, 16), ctx.regs.named.r15);
    try std.testing.expectEqual(@as(u64, 8), ctx.sp);
    try std.testing.expectEqual(@as(u64, 17), ctx.pc);
    try std.testing.expectEqual(@as(u64, 18), ctx.flags);
    try std.testing.expectEqual(@as(u64, 19), ctx.cs);
    try std.testing.expectEqual(@as(u64, 20), ctx.fs);
    try std.testing.expectEqual(@as(u64, 21), ctx.gs);
    try std.testing.expectEqual(@as(u128, 0x1122_3344_5566_7788), ctx.fpregs.named.xmm0);
    try std.testing.expectEqual((@as(u128, 0xAAAA_BBBB_CCCC_DDDD) << 64) | 0xEEEE_FFFF_0000_1111, ctx.fpregs.named.xmm15);
    try std.testing.expectEqual(@as(u32, 0x2222), ctx.mxcsr);

    ctx.regs.named.rax = 0xDEAD;
    ctx.regs.named.r15 = 0xBEEF;
    ctx.sp = 0xCAFE;
    ctx.pc = 0x1111;
    ctx.flags = 0x2222;
    ctx.cs = 0x33;
    ctx.fs = 0x44;
    ctx.gs = 0x55;
    ctx.fpregs.named.xmm0 = 0x6666_7777_8888_9999;
    ctx.fpregs.named.xmm15 = (@as(u128, 0x1234_5678_9ABC_DEF0) << 64) | 0x0FED_CBA9_8765_4321;
    ctx.mxcsr = 0x7777;

    writeBackToMcontext(&mcontext, &ctx);

    try std.testing.expectEqual(@as(u64, 0xDEAD), mcontext.ss.rax);
    try std.testing.expectEqual(@as(u64, 0xBEEF), mcontext.ss.r15);
    try std.testing.expectEqual(@as(u64, 0xCAFE), mcontext.ss.rsp);
    try std.testing.expectEqual(@as(u64, 0x1111), mcontext.ss.rip);
    try std.testing.expectEqual(@as(u64, 0x2222), mcontext.ss.rflags);
    try std.testing.expectEqual(@as(u64, 0x33), mcontext.ss.cs);
    try std.testing.expectEqual(@as(u64, 0x44), mcontext.ss.fs);
    try std.testing.expectEqual(@as(u64, 0x55), mcontext.ss.gs);
    try std.testing.expectEqual(@as(u128, 0x6666_7777_8888_9999), readU128(mcontext.fs.xmm[0][0..]));
    try std.testing.expectEqual((@as(u128, 0x1234_5678_9ABC_DEF0) << 64) | 0x0FED_CBA9_8765_4321, readU128(mcontext.fs.xmm[15][0..]));
    try std.testing.expectEqual(@as(u32, 0x7777), mcontext.fs.mxcsr);
}
