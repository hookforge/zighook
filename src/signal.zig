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
const arch = @import("arch/root.zig");
const state = @import("state.zig");

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

/// Applies the runtime hook policy for a trapped instruction.
///
/// Callback contract:
/// - if the callback overwrites `ctx.pc`, zighook respects that decision
/// - otherwise `inline_hook` returns to the caller using the current ISA ABI
/// - otherwise `instrument` uses the precomputed replay plan
/// - otherwise `instrument_no_original` skips to the next instruction
fn handleTrap(address: u64, ctx: *arch.HookContext) bool {
    const slot = state.slotByAddress(address) orelse return false;
    const callback = slot.callback orelse return false;

    const original_pc = ctx.pc;
    callback(address, ctx);

    if (ctx.pc != original_pc) return true;

    if (slot.return_to_caller) {
        arch.returnToCaller(ctx) catch return false;
        return true;
    }

    const next_pc = address + slot.step_len;
    if (slot.execute_original) {
        if (slot.replay_plan.requiresTrampoline()) {
            ctx.pc = slot.trampoline_pc;
        } else {
            arch.applyReplay(slot.replay_plan, address, ctx) catch return false;
        }
    } else {
        ctx.pc = next_pc;
    }
    return true;
}

/// Process-wide `SIGTRAP` / `SIGILL` handler used by the current backend.
///
/// The handler does not allocate and only performs a small amount of work:
/// - recover the trapped PC from the OS signal frame
/// - copy native machine state into the public callback layout
/// - verify that the instruction at that PC is still `brk`
/// - dispatch to the registered callback
/// - write the edited context back so execution resumes as requested
fn trapHandler(signum: c_int, info: *const std.c.siginfo_t, uctx_opaque: ?*anyopaque) callconv(.c) void {
    var ctx = arch.captureMachineContext(uctx_opaque) orelse {
        chainPrevious(signum, info, uctx_opaque);
        return;
    };
    const trap_address = arch.trapAddress(&ctx) catch {
        chainPrevious(signum, info, uctx_opaque);
        return;
    };
    arch.normalizeTrapContext(&ctx, trap_address);

    if (!(arch.isTrapInstruction(trap_address) catch false)) {
        chainPrevious(signum, info, uctx_opaque);
        return;
    }

    if (!handleTrap(trap_address, &ctx)) {
        chainPrevious(signum, info, uctx_opaque);
        return;
    }

    if (!arch.writeBackMachineContext(uctx_opaque, &ctx)) {
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
