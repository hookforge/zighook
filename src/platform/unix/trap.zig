//! Shared Unix trap-handler installation and signal dispatch.
//!
//! macOS, iOS, Linux, and Android all expose the same broad `sigaction`
//! control flow for process-global trap handling even though their native
//! thread-context layouts differ. This file centralizes the common Unix signal
//! chaining logic while ISA-specific context capture remains in `arch/*`.

const std = @import("std");

const HookError = @import("../../error.zig").HookError;
const arch = @import("../../arch/root.zig");
const dispatch = @import("../../runtime/dispatch.zig");

var handlers_installed = false;
var prev_sigtrap_action: ?std.c.Sigaction = null;
var prev_sigill_action: ?std.c.Sigaction = null;

fn raiseWithDefault(signum: c_int) void {
    // Reinstall the default disposition before re-raising the signal. This
    // preserves the expected Unix behavior for faults we do not claim and
    // avoids recursively re-entering zighook's handler forever.
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

fn chainPrevious(signum: c_int, info: *const std.c.siginfo_t, uctx: ?*anyopaque) void {
    // zighook only owns traps that map to a registered patch point. Every
    // other signal instance must keep the host process's original semantics,
    // including custom signal handlers that were already installed before us.
    const previous = previousAction(signum) orelse {
        raiseWithDefault(signum);
        return;
    };

    if ((previous.flags & std.c.SA.SIGINFO) != 0) {
        // Preserve SA_SIGINFO handlers exactly: forward the original triple so
        // the host sees the same signal metadata and ucontext pointer.
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

    // Honor the standard Unix special handlers first. For a default handler we
    // reinstall `SIG_DFL` and re-raise so the kernel delivers the signal as if
    // zighook had never intercepted it.
    if (previous_handler == std.c.SIG.IGN) return;
    if (previous_handler == std.c.SIG.DFL) {
        raiseWithDefault(signum);
        return;
    }

    previous_handler(signum);
}

fn trapHandler(signum: c_int, info: *const std.c.siginfo_t, uctx_opaque: ?*anyopaque) callconv(.c) void {
    // The platform layer's only job is to lift the native `ucontext_t`
    // representation into the stable ISA-specific HookContext. Once we have
    // that normalized view, the runtime policy becomes architecture-neutral.
    var ctx = arch.captureMachineContext(uctx_opaque) orelse {
        chainPrevious(signum, info, uctx_opaque);
        return;
    };
    const trap_address = arch.trapAddress(&ctx) catch {
        chainPrevious(signum, info, uctx_opaque);
        return;
    };

    // Some ISAs report `pc` at the trap instruction while others advance it to
    // the following address. Normalize here so dispatch code can always key the
    // hook table by the actual patched instruction address.
    arch.normalizeTrapContext(&ctx, trap_address);

    if (!(arch.isTrapInstruction(trap_address) catch false)) {
        chainPrevious(signum, info, uctx_opaque);
        return;
    }

    if (!dispatch.handleTrap(trap_address, &ctx)) {
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

/// Installs zighook's Unix trap handlers on first use.
///
/// The installation is process-global because `sigaction` itself is
/// process-global. The handlers are chained with any previously installed
/// `SIGTRAP` or `SIGILL` actions so the embedding application keeps its own
/// behavior for unrelated signals.
pub fn ensureHandlersInstalled() HookError!void {
    if (handlers_installed) return;

    try installSignal(std.c.SIG.TRAP);
    try installSignal(std.c.SIG.ILL);
    handlers_installed = true;
}
