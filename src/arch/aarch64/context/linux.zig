//! Linux / Android AArch64 signal-context remapping.
//!
//! Linux-family AArch64 targets expose general-purpose state directly in
//! `mcontext_t`, while FP/SIMD state lives in extensible records stored inside
//! the reserved signal-frame area. Android follows the same kernel ABI here.

const std = @import("std");

const types = @import("types.zig");

const linux = std.os.linux;
const LinuxMContext = linux.mcontext_t;

const fpsimd_magic: u32 = 0x4650_8001;
const extra_magic: u32 = 0x4558_5401;

const Aarch64Ctx = extern struct {
    magic: u32,
    size: u32,
};

const FpsimdContext = extern struct {
    head: Aarch64Ctx,
    fpsr: u32,
    fpcr: u32,
    vregs: [32]u128,
};

const ExtraContext = extern struct {
    head: Aarch64Ctx,
    datap: u64,
    size: u32,
    reserved: [3]u32,
};

fn align16(size: usize) usize {
    return (size + 15) & ~@as(usize, 15);
}

fn reservedBytesConst(mcontext: *const LinuxMContext) []align(16) const u8 {
    const ptr: [*]align(16) const u8 = @ptrCast(&mcontext.reserved1);
    return ptr[0..mcontext.reserved1.len];
}

fn reservedBytesMut(mcontext: *LinuxMContext) []align(16) u8 {
    const ptr: [*]align(16) u8 = @ptrCast(&mcontext.reserved1);
    return ptr[0..mcontext.reserved1.len];
}

fn findFpsimdRecordConstInRegion(records: []align(16) const u8) ?*align(16) const FpsimdContext {
    var offset: usize = 0;
    while (offset + @sizeOf(Aarch64Ctx) <= records.len) {
        const header_ptr: *align(16) const Aarch64Ctx = @ptrCast(@alignCast(records.ptr + offset));
        const header = header_ptr.*;

        if (header.magic == 0 and header.size == 0) return null;

        const size = @as(usize, header.size);
        if (size < @sizeOf(Aarch64Ctx) or offset + size > records.len) return null;

        if (header.magic == fpsimd_magic) {
            if (size < @sizeOf(FpsimdContext)) return null;
            return @ptrCast(header_ptr);
        }

        if (header.magic == extra_magic and size >= @sizeOf(ExtraContext)) {
            const extra_ptr: *align(16) const ExtraContext = @ptrCast(header_ptr);
            if (extra_ptr.datap != 0 and extra_ptr.size >= @sizeOf(Aarch64Ctx)) {
                const extra_records_ptr: [*]align(16) const u8 = @ptrFromInt(extra_ptr.datap);
                const extra_records = extra_records_ptr[0..extra_ptr.size];
                if (findFpsimdRecordConstInRegion(extra_records)) |fpsimd| return fpsimd;
            }
        }

        offset += align16(size);
    }
    return null;
}

fn findFpsimdRecordMutInRegion(records: []align(16) u8) ?*align(16) FpsimdContext {
    var offset: usize = 0;
    while (offset + @sizeOf(Aarch64Ctx) <= records.len) {
        const header_ptr: *align(16) Aarch64Ctx = @ptrCast(@alignCast(records.ptr + offset));
        const header = header_ptr.*;

        if (header.magic == 0 and header.size == 0) return null;

        const size = @as(usize, header.size);
        if (size < @sizeOf(Aarch64Ctx) or offset + size > records.len) return null;

        if (header.magic == fpsimd_magic) {
            if (size < @sizeOf(FpsimdContext)) return null;
            return @ptrCast(header_ptr);
        }

        if (header.magic == extra_magic and size >= @sizeOf(ExtraContext)) {
            const extra_ptr: *align(16) ExtraContext = @ptrCast(header_ptr);
            if (extra_ptr.datap != 0 and extra_ptr.size >= @sizeOf(Aarch64Ctx)) {
                const extra_records_ptr: [*]align(16) u8 = @ptrFromInt(extra_ptr.datap);
                const extra_records = extra_records_ptr[0..extra_ptr.size];
                if (findFpsimdRecordMutInRegion(extra_records)) |fpsimd| return fpsimd;
            }
        }

        offset += align16(size);
    }
    return null;
}

fn findFpsimdRecordConst(mcontext: *const LinuxMContext) ?*align(16) const FpsimdContext {
    return findFpsimdRecordConstInRegion(reservedBytesConst(mcontext));
}

fn findFpsimdRecordMut(mcontext: *LinuxMContext) ?*align(16) FpsimdContext {
    return findFpsimdRecordMutInRegion(reservedBytesMut(mcontext));
}

fn captureFromMcontext(mcontext: *const LinuxMContext) types.HookContext {
    var ctx = std.mem.zeroes(types.HookContext);

    for (mcontext.regs, 0..) |reg, index| {
        ctx.regs.x[index] = @intCast(reg);
    }
    ctx.sp = @intCast(mcontext.sp);
    ctx.pc = @intCast(mcontext.pc);
    ctx.cpsr = @truncate(mcontext.pstate);
    ctx.pad = 0;

    if (findFpsimdRecordConst(mcontext)) |fpsimd| {
        @memcpy(ctx.fpregs.v[0..], fpsimd.vregs[0..]);
        ctx.fpsr = fpsimd.fpsr;
        ctx.fpcr = fpsimd.fpcr;
    }

    return ctx;
}

fn writeBackToMcontext(mcontext: *LinuxMContext, ctx: *const types.HookContext) void {
    for (ctx.regs.x, 0..) |reg, index| {
        mcontext.regs[index] = @intCast(reg);
    }
    mcontext.sp = @intCast(ctx.sp);
    mcontext.pc = @intCast(ctx.pc);
    mcontext.pstate = @intCast(ctx.cpsr);

    if (findFpsimdRecordMut(mcontext)) |fpsimd| {
        @memcpy(fpsimd.vregs[0..], ctx.fpregs.v[0..]);
        fpsimd.fpsr = ctx.fpsr;
        fpsimd.fpcr = ctx.fpcr;
    }
}

/// Copies a Linux / Android signal frame into the stable public callback layout.
pub fn captureMachineContext(uctx_opaque: ?*anyopaque) ?types.HookContext {
    if (uctx_opaque == null) return null;

    const uctx: *align(1) linux.ucontext_t = @ptrCast(uctx_opaque.?);
    const mcontext: *const LinuxMContext = @alignCast(&uctx.mcontext);
    return captureFromMcontext(mcontext);
}

/// Writes a callback-edited public context back into a Linux / Android signal frame.
pub fn writeBackMachineContext(uctx_opaque: ?*anyopaque, ctx: *const types.HookContext) bool {
    if (uctx_opaque == null) return false;

    const uctx: *align(1) linux.ucontext_t = @ptrCast(uctx_opaque.?);
    const mcontext: *LinuxMContext = @alignCast(&uctx.mcontext);
    writeBackToMcontext(mcontext, ctx);
    return true;
}

test "Linux AArch64 signal context remaps integer and FP state through fpsimd records" {
    var mcontext = std.mem.zeroes(LinuxMContext);

    for (&mcontext.regs, 0..) |*reg, index| {
        reg.* = 0x1000 + index;
    }
    mcontext.sp = 0x2000;
    mcontext.pc = 0x3000;
    mcontext.pstate = 0x4000;

    const reserved = reservedBytesMut(&mcontext);
    const fpsimd: *align(16) FpsimdContext = @ptrCast(reserved.ptr);
    fpsimd.* = .{
        .head = .{ .magic = fpsimd_magic, .size = @sizeOf(FpsimdContext) },
        .fpsr = 0x5000,
        .fpcr = 0x6000,
        .vregs = undefined,
    };
    for (&fpsimd.vregs, 0..) |*reg, index| {
        reg.* = (@as(u128, index) << 64) | (0xA0 + index);
    }

    const terminator_offset = @sizeOf(FpsimdContext);
    const terminator: *align(16) Aarch64Ctx = @ptrCast(reserved.ptr + terminator_offset);
    terminator.* = .{ .magic = 0, .size = 0 };

    var ctx = captureFromMcontext(&mcontext);

    try std.testing.expectEqual(@as(u64, 0x1000), ctx.regs.x[0]);
    try std.testing.expectEqual(@as(u64, 0x101E), ctx.regs.x[30]);
    try std.testing.expectEqual(@as(u64, 0x2000), ctx.sp);
    try std.testing.expectEqual(@as(u64, 0x3000), ctx.pc);
    try std.testing.expectEqual(@as(u32, 0x4000), ctx.cpsr);
    try std.testing.expectEqual((@as(u128, 31) << 64) | 0xBF, ctx.fpregs.named.v31);
    try std.testing.expectEqual(@as(u32, 0x5000), ctx.fpsr);
    try std.testing.expectEqual(@as(u32, 0x6000), ctx.fpcr);

    ctx.regs.named.x0 = 0xDEAD;
    ctx.regs.named.x30 = 0xBEEF;
    ctx.sp = 0xCAFE;
    ctx.pc = 0x1111;
    ctx.cpsr = 0x2222;
    ctx.fpregs.named.v0 = 0x1122_3344_5566_7788;
    ctx.fpregs.named.v31 = (@as(u128, 0x9999_AAAA_BBBB_CCCC) << 64) | 0xDDDD_EEEE_FFFF_0000;
    ctx.fpsr = 0x3333;
    ctx.fpcr = 0x4444;

    writeBackToMcontext(&mcontext, &ctx);

    try std.testing.expectEqual(@as(usize, 0xDEAD), mcontext.regs[0]);
    try std.testing.expectEqual(@as(usize, 0xBEEF), mcontext.regs[30]);
    try std.testing.expectEqual(@as(usize, 0xCAFE), mcontext.sp);
    try std.testing.expectEqual(@as(usize, 0x1111), mcontext.pc);
    try std.testing.expectEqual(@as(usize, 0x2222), mcontext.pstate);
    try std.testing.expectEqual(@as(u128, 0x1122_3344_5566_7788), fpsimd.vregs[0]);
    try std.testing.expectEqual((@as(u128, 0x9999_AAAA_BBBB_CCCC) << 64) | 0xDDDD_EEEE_FFFF_0000, fpsimd.vregs[31]);
    try std.testing.expectEqual(@as(u32, 0x3333), fpsimd.fpsr);
    try std.testing.expectEqual(@as(u32, 0x4444), fpsimd.fpcr);
}
