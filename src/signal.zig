//! Trap signal installation and dispatch.
//!
//! The current backend is intentionally conservative:
//! - a single in-process registry
//! - process-wide signal handlers
//! - no attempt at thread isolation yet
//! - callback dispatch by exact trapped address
//!
//! This mirrors the original Rust crate's "single-thread experimental runtime"
//! trade-off and keeps the rewrite small enough to reason about.

const std = @import("std");

const HookError = @import("error.zig").HookError;
const context = @import("context.zig");
const state = @import("state.zig");
const memory = @import("memory.zig");

var handlers_installed = false;
var prev_sigtrap_action: ?std.c.Sigaction = null;
var prev_sigill_action: ?std.c.Sigaction = null;

/// Re-raises the signal with default disposition so the process still behaves
/// like an ordinary crashing process when the trap does not belong to us.
fn raiseWithDefault(signum: c_int) void {
    var default_action = std.mem.zeroes(std.c.Sigaction);
    default_action.handler = .{ .handler = std.c.SIG.DFL };
    default_action.flags = 0;
    _ = std.c.sigemptyset(&default_action.mask);
    _ = std.c.sigaction(signum, &default_action, null);
    _ = std.c.raise(signum);
}

fn previousAction(signum: c_int) ?std.c.Sigaction {
    return switch (signum) {
        std.c.SIG.TRAP => prev_sigtrap_action,
        std.c.SIG.ILL => prev_sigill_action,
        else => null,
    };
}

fn savePreviousAction(signum: c_int, action: std.c.Sigaction) void {
    switch (signum) {
        std.c.SIG.TRAP => prev_sigtrap_action = action,
        std.c.SIG.ILL => prev_sigill_action = action,
        else => {},
    }
}

/// Falls back to the handler that was installed before zighook, preserving the
/// host application's original signal behavior when a trap is unrelated to us.
fn chainPrevious(signum: c_int, info: *const std.c.siginfo_t, uctx: ?*anyopaque) void {
    const previous = previousAction(signum) orelse {
        raiseWithDefault(signum);
        return;
    };

    if ((previous.flags & std.c.SA.SIGINFO) != 0) {
        const previous_handler = previous.handler.sigaction orelse {
            raiseWithDefault(signum);
            return;
        };
        previous_handler(signum, info, uctx);
        return;
    }

    const previous_handler = previous.handler.handler orelse {
        raiseWithDefault(signum);
        return;
    };

    if (previous_handler == std.c.SIG.IGN) return;
    if (previous_handler == std.c.SIG.DFL) {
        raiseWithDefault(signum);
        return;
    }

    previous_handler(signum);
}

/// Applies the runtime hook policy for a trapped AArch64 instruction.
///
/// Callback contract:
/// - if the callback overwrites `ctx.pc`, zighook respects that decision
/// - otherwise `inline_hook` returns to `lr`
/// - otherwise `instrument` continues via the replay trampoline
/// - otherwise `instrument_no_original` skips to the next instruction
fn handleTrapAarch64(address: u64, ctx: *context.HookContext) bool {
    const slot = state.slotByAddress(address) orelse return false;
    const callback = slot.callback orelse return false;

    const original_pc = ctx.pc;
    callback(address, ctx);

    if (ctx.pc != original_pc) return true;

    if (slot.return_to_caller) {
        ctx.pc = ctx.regs.named.x30;
        return true;
    }

    const next_pc = address + slot.step_len;
    if (slot.execute_original) {
        ctx.pc = slot.trampoline_pc;
    } else {
        ctx.pc = next_pc;
    }
    return true;
}

/// Process-wide `SIGTRAP` / `SIGILL` handler used by the current backend.
///
/// The handler does not allocate and only performs a small amount of work:
/// - recover the trapped PC from `ucontext`
/// - verify that the instruction at that PC is still `brk`
/// - dispatch to the registered callback
/// - rewrite `ctx.pc` so execution resumes as requested
fn trapHandler(signum: c_int, info: *const std.c.siginfo_t, uctx_opaque: ?*anyopaque) callconv(.c) void {
    if (uctx_opaque == null) {
        chainPrevious(signum, info, uctx_opaque);
        return;
    }

    // Darwin may hand signal handlers a context pointer that is not naturally
    // aligned for Zig's `ucontext_t` view. Follow the same defensive pattern
    // used by `std.debug` and treat the outer frame as byte-aligned.
    const uctx: *align(1) std.c.ucontext_t = @ptrCast(uctx_opaque.?);
    const mcontext = uctx.mcontext;
    const ctx = context.fromThreadState(&mcontext.ss);
    const trap_address = ctx.pc;

    const opcode = memory.readU32(trap_address) catch {
        chainPrevious(signum, info, uctx_opaque);
        return;
    };
    if (!memory.isBrk(opcode)) {
        chainPrevious(signum, info, uctx_opaque);
        return;
    }

    if (!handleTrapAarch64(trap_address, ctx)) {
        chainPrevious(signum, info, uctx_opaque);
    }
}

fn installSignal(signum: c_int) HookError!void {
    var action = std.mem.zeroes(std.c.Sigaction);
    var previous = std.mem.zeroes(std.c.Sigaction);

    action.handler = .{ .sigaction = trapHandler };
    action.flags = std.c.SA.SIGINFO;

    if (std.c.sigemptyset(&action.mask) != 0) {
        return error.SignalMaskInitFailed;
    }

    if (std.c.sigaction(signum, &action, &previous) != 0) {
        return error.SignalHandlerInstallFailed;
    }

    savePreviousAction(signum, previous);
}

/// Installs the trap signal handlers once per process.
///
/// The first successful runtime trap hook pays this setup cost. Later calls are
/// cheap no-ops.
pub fn ensureHandlersInstalled() HookError!void {
    if (handlers_installed) return;

    try installSignal(std.c.SIG.TRAP);
    try installSignal(std.c.SIG.ILL);
    handlers_installed = true;
}
