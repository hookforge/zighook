//! Shared public x86_64 callback context types.
//!
//! Darwin and Linux expose different native signal-frame layouts, but this file
//! defines the stable callback-facing register view used by the x86_64 backend.

const std = @import("std");

pub const GpRegistersNamed = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
};

pub const GpRegisters = extern union {
    gpr: [15]u64,
    named: GpRegistersNamed,
};

pub const FpRegistersNamed = extern struct {
    xmm0: u128,
    xmm1: u128,
    xmm2: u128,
    xmm3: u128,
    xmm4: u128,
    xmm5: u128,
    xmm6: u128,
    xmm7: u128,
    xmm8: u128,
    xmm9: u128,
    xmm10: u128,
    xmm11: u128,
    xmm12: u128,
    xmm13: u128,
    xmm14: u128,
    xmm15: u128,
};

pub const FpRegisters = extern union {
    xmm: [16]u128,
    named: FpRegistersNamed,
};

pub const HookContext = extern struct {
    regs: GpRegisters,
    sp: u64,
    pc: u64,
    flags: u64,
    cs: u64,
    fs: u64,
    gs: u64,
    fpregs: FpRegisters,
    mxcsr: u32,
    fp_pad: u32,
};

comptime {
    std.debug.assert(@sizeOf(GpRegisters) == @sizeOf([15]u64));
    std.debug.assert(@sizeOf(FpRegisters) == @sizeOf([16]u128));
    std.debug.assert(@alignOf(FpRegisters) == @alignOf([16]u128));
}

pub const InstrumentCallback = *const fn (address: u64, ctx: *HookContext) callconv(.c) void;
