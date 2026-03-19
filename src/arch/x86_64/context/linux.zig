//! Linux x86_64 signal-context remapping.

const std = @import("std");

const linux = std.os.linux;
const REG = linux.REG;
const LinuxMContext = linux.mcontext_t;

const types = @import("types.zig");

/// Linux x86_64 stores the architectural segment selectors inside the packed
/// `REG.CSGSFS` greg slot. Keeping this layout explicit makes the trap-frame
/// mapping much easier to audit against the kernel ABI:
/// - bits 0..15   = CS
/// - bits 16..31  = GS
/// - bits 32..47  = FS
/// - bits 48..63  = SS
///
/// Recent kernels set `UC_SIGCONTEXT_SS` / `UC_STRICT_RESTORE_SS`, which means
/// the top 16 bits are no longer padding for ordinary 64-bit signal delivery.
/// We therefore preserve the full packed value instead of reconstructing only
/// `cs`, `gs`, and `fs`.
const SegmentSelectors = packed struct(u64) {
    cs: u16,
    gs: u16,
    fs: u16,
    ss: u16,
};

fn readU128(bytes: []const u8) u128 {
    return std.mem.readInt(u128, bytes[0..16], .little);
}

fn writeU128(bytes: []u8, value: u128) void {
    std.mem.writeInt(u128, bytes[0..16], value, .little);
}

fn captureFromMcontext(mcontext: *const LinuxMContext) types.HookContext {
    var ctx = std.mem.zeroes(types.HookContext);

    ctx.regs.named.rax = @intCast(mcontext.gregs[REG.RAX]);
    ctx.regs.named.rbx = @intCast(mcontext.gregs[REG.RBX]);
    ctx.regs.named.rcx = @intCast(mcontext.gregs[REG.RCX]);
    ctx.regs.named.rdx = @intCast(mcontext.gregs[REG.RDX]);
    ctx.regs.named.rdi = @intCast(mcontext.gregs[REG.RDI]);
    ctx.regs.named.rsi = @intCast(mcontext.gregs[REG.RSI]);
    ctx.regs.named.rbp = @intCast(mcontext.gregs[REG.RBP]);
    ctx.regs.named.r8 = @intCast(mcontext.gregs[REG.R8]);
    ctx.regs.named.r9 = @intCast(mcontext.gregs[REG.R9]);
    ctx.regs.named.r10 = @intCast(mcontext.gregs[REG.R10]);
    ctx.regs.named.r11 = @intCast(mcontext.gregs[REG.R11]);
    ctx.regs.named.r12 = @intCast(mcontext.gregs[REG.R12]);
    ctx.regs.named.r13 = @intCast(mcontext.gregs[REG.R13]);
    ctx.regs.named.r14 = @intCast(mcontext.gregs[REG.R14]);
    ctx.regs.named.r15 = @intCast(mcontext.gregs[REG.R15]);
    ctx.sp = @intCast(mcontext.gregs[REG.RSP]);
    ctx.pc = @intCast(mcontext.gregs[REG.RIP]);
    ctx.flags = @intCast(mcontext.gregs[REG.EFL]);

    const selectors: SegmentSelectors = @bitCast(@as(u64, @intCast(mcontext.gregs[REG.CSGSFS])));
    ctx.cs = selectors.cs;
    ctx.gs = selectors.gs;
    ctx.fs = selectors.fs;
    ctx.ss = selectors.ss;

    if (@intFromPtr(mcontext.fpregs) != 0) {
        for (mcontext.fpregs.xmm, 0..) |xmm, index| {
            ctx.fpregs.xmm[index] = readU128(std.mem.asBytes(&xmm));
        }
        ctx.mxcsr = mcontext.fpregs.mxcsr;
    }

    return ctx;
}

fn writeBackToMcontext(mcontext: *LinuxMContext, ctx: *const types.HookContext) void {
    mcontext.gregs[REG.RAX] = @intCast(ctx.regs.named.rax);
    mcontext.gregs[REG.RBX] = @intCast(ctx.regs.named.rbx);
    mcontext.gregs[REG.RCX] = @intCast(ctx.regs.named.rcx);
    mcontext.gregs[REG.RDX] = @intCast(ctx.regs.named.rdx);
    mcontext.gregs[REG.RDI] = @intCast(ctx.regs.named.rdi);
    mcontext.gregs[REG.RSI] = @intCast(ctx.regs.named.rsi);
    mcontext.gregs[REG.RBP] = @intCast(ctx.regs.named.rbp);
    mcontext.gregs[REG.R8] = @intCast(ctx.regs.named.r8);
    mcontext.gregs[REG.R9] = @intCast(ctx.regs.named.r9);
    mcontext.gregs[REG.R10] = @intCast(ctx.regs.named.r10);
    mcontext.gregs[REG.R11] = @intCast(ctx.regs.named.r11);
    mcontext.gregs[REG.R12] = @intCast(ctx.regs.named.r12);
    mcontext.gregs[REG.R13] = @intCast(ctx.regs.named.r13);
    mcontext.gregs[REG.R14] = @intCast(ctx.regs.named.r14);
    mcontext.gregs[REG.R15] = @intCast(ctx.regs.named.r15);
    mcontext.gregs[REG.RSP] = @intCast(ctx.sp);
    mcontext.gregs[REG.RIP] = @intCast(ctx.pc);
    mcontext.gregs[REG.EFL] = @intCast(ctx.flags);
    const selectors = SegmentSelectors{
        .cs = @truncate(ctx.cs),
        .gs = @truncate(ctx.gs),
        .fs = @truncate(ctx.fs),
        .ss = @truncate(ctx.ss),
    };
    mcontext.gregs[REG.CSGSFS] = @intCast(@as(u64, @bitCast(selectors)));

    if (@intFromPtr(mcontext.fpregs) != 0) {
        for (ctx.fpregs.xmm, 0..) |xmm, index| {
            writeU128(std.mem.asBytes(&mcontext.fpregs.xmm[index]), xmm);
        }
        mcontext.fpregs.mxcsr = ctx.mxcsr;
    }
}

pub fn captureMachineContext(uctx_opaque: ?*anyopaque) ?types.HookContext {
    if (uctx_opaque == null) return null;

    const uctx: *align(1) linux.ucontext_t = @ptrCast(uctx_opaque.?);
    const mcontext: *const LinuxMContext = @alignCast(&uctx.mcontext);
    return captureFromMcontext(mcontext);
}

pub fn writeBackMachineContext(uctx_opaque: ?*anyopaque, ctx: *const types.HookContext) bool {
    if (uctx_opaque == null) return false;

    const uctx: *align(1) linux.ucontext_t = @ptrCast(uctx_opaque.?);
    const mcontext: *LinuxMContext = @alignCast(&uctx.mcontext);
    writeBackToMcontext(mcontext, ctx);
    return true;
}

test "Linux x86_64 signal context remaps GPRs and XMM state" {
    var fpstate = std.mem.zeroes(linux.fpstate);
    var mcontext = std.mem.zeroes(LinuxMContext);
    mcontext.fpregs = &fpstate;

    mcontext.gregs[REG.RAX] = 1;
    mcontext.gregs[REG.RBX] = 2;
    mcontext.gregs[REG.RCX] = 3;
    mcontext.gregs[REG.RDX] = 4;
    mcontext.gregs[REG.RDI] = 5;
    mcontext.gregs[REG.RSI] = 6;
    mcontext.gregs[REG.RBP] = 7;
    mcontext.gregs[REG.R8] = 8;
    mcontext.gregs[REG.R9] = 9;
    mcontext.gregs[REG.R10] = 10;
    mcontext.gregs[REG.R11] = 11;
    mcontext.gregs[REG.R12] = 12;
    mcontext.gregs[REG.R13] = 13;
    mcontext.gregs[REG.R14] = 14;
    mcontext.gregs[REG.R15] = 15;
    mcontext.gregs[REG.RSP] = 16;
    mcontext.gregs[REG.RIP] = 17;
    mcontext.gregs[REG.EFL] = 18;
    mcontext.gregs[REG.CSGSFS] = 0x0033 |
        (@as(usize, 0x0044) << 16) |
        (@as(usize, 0x0055) << 32) |
        (@as(usize, 0x0066) << 48);
    writeU128(std.mem.asBytes(&fpstate.xmm[0]), 0x1122_3344_5566_7788);
    writeU128(std.mem.asBytes(&fpstate.xmm[15]), (@as(u128, 0xAAAA_BBBB_CCCC_DDDD) << 64) | 0xEEEE_FFFF_0000_1111);
    fpstate.mxcsr = 0x6666;

    var ctx = captureFromMcontext(&mcontext);

    try std.testing.expectEqual(@as(u64, 1), ctx.regs.named.rax);
    try std.testing.expectEqual(@as(u64, 15), ctx.regs.named.r15);
    try std.testing.expectEqual(@as(u64, 16), ctx.sp);
    try std.testing.expectEqual(@as(u64, 17), ctx.pc);
    try std.testing.expectEqual(@as(u64, 18), ctx.flags);
    try std.testing.expectEqual(@as(u64, 0x33), ctx.cs);
    try std.testing.expectEqual(@as(u64, 0x44), ctx.gs);
    try std.testing.expectEqual(@as(u64, 0x55), ctx.fs);
    try std.testing.expectEqual(@as(u64, 0x66), ctx.ss);
    try std.testing.expectEqual(@as(u128, 0x1122_3344_5566_7788), ctx.fpregs.named.xmm0);
    try std.testing.expectEqual((@as(u128, 0xAAAA_BBBB_CCCC_DDDD) << 64) | 0xEEEE_FFFF_0000_1111, ctx.fpregs.named.xmm15);
    try std.testing.expectEqual(@as(u32, 0x6666), ctx.mxcsr);

    ctx.regs.named.rax = 0xDEAD;
    ctx.regs.named.r15 = 0xBEEF;
    ctx.sp = 0xCAFE;
    ctx.pc = 0x1111;
    ctx.flags = 0x2222;
    ctx.cs = 0x77;
    ctx.gs = 0x88;
    ctx.fs = 0x99;
    ctx.ss = 0xAA;
    ctx.fpregs.named.xmm0 = 0xABCD_EF01_2345_6789;
    ctx.fpregs.named.xmm15 = (@as(u128, 0x1234_5678_9ABC_DEF0) << 64) | 0x0FED_CBA9_8765_4321;
    ctx.mxcsr = 0x3333;

    writeBackToMcontext(&mcontext, &ctx);

    try std.testing.expectEqual(@as(usize, 0xDEAD), mcontext.gregs[REG.RAX]);
    try std.testing.expectEqual(@as(usize, 0xBEEF), mcontext.gregs[REG.R15]);
    try std.testing.expectEqual(@as(usize, 0xCAFE), mcontext.gregs[REG.RSP]);
    try std.testing.expectEqual(@as(usize, 0x1111), mcontext.gregs[REG.RIP]);
    try std.testing.expectEqual(@as(usize, 0x2222), mcontext.gregs[REG.EFL]);
    try std.testing.expectEqual(
        @as(usize, 0x77) |
            (@as(usize, 0x88) << 16) |
            (@as(usize, 0x99) << 32) |
            (@as(usize, 0xAA) << 48),
        mcontext.gregs[REG.CSGSFS],
    );
    try std.testing.expectEqual(@as(u128, 0xABCD_EF01_2345_6789), readU128(std.mem.asBytes(&fpstate.xmm[0])));
    try std.testing.expectEqual((@as(u128, 0x1234_5678_9ABC_DEF0) << 64) | 0x0FED_CBA9_8765_4321, readU128(std.mem.asBytes(&fpstate.xmm[15])));
    try std.testing.expectEqual(@as(u32, 0x3333), fpstate.mxcsr);
}
