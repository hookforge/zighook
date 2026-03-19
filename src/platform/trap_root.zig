//! Compile-time selector for platform trap backends.
//!
//! The public runtime code should not need to know whether trap delivery comes
//! from a Unix `sigaction` backend or a future Windows exception backend.
//! This file is the narrow compile-time seam that chooses the active platform
//! implementation and presents a small stable surface to the rest of zighook.

const builtin = @import("builtin");
const HookError = @import("../error.zig").HookError;

const current = switch (builtin.os.tag) {
    .macos, .ios, .linux => @import("unix/trap.zig"),
    else => @compileError("zighook trap handling is currently implemented for Unix-family targets only."),
};

/// Installs the process-global trap backend the first time a hook is
/// registered.
///
/// This function is intentionally idempotent. Callers do not need to cache the
/// installation state themselves; repeated calls simply become no-ops once the
/// backend is live.
pub fn ensureHandlersInstalled() HookError!void {
    return current.ensureHandlersInstalled();
}
