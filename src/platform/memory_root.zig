//! Compile-time selector for platform executable-memory backends.
//!
//! Hook installation and trampoline construction need a tiny set of
//! platform-sensitive primitives:
//! - temporarily make executable pages writable
//! - flush the instruction cache after self-modifying code
//! - allocate/free scratch pages for out-of-line trampolines
//!
//! The rest of the library talks to this module rather than importing
//! Linux/Darwin details directly.

const builtin = @import("builtin");
const std = @import("std");
const HookError = @import("../error.zig").HookError;

pub const TrampolineKind = @import("types.zig").TrampolineKind;

const current = switch (builtin.os.tag) {
    .macos, .ios => @import("unix/darwin/memory.zig"),
    .linux => @import("unix/linux/memory.zig"),
    else => @compileError("zighook executable-memory helpers are currently implemented for Darwin and Linux only."),
};

/// Writes replacement machine code bytes into the current process image.
pub fn patchBytes(address: u64, bytes: []const u8) HookError!void {
    return current.patchBytes(address, bytes);
}

/// Flushes the instruction cache for a modified code range.
pub fn flushInstructionCache(address: [*]u8, len: usize) void {
    current.flushInstructionCache(address, len);
}

/// Allocates a writable trampoline page near `address_hint` when the selected
/// `kind` requires locality.
pub fn allocateTrampolinePage(address_hint: u64, kind: TrampolineKind) HookError![]align(std.heap.page_size_min) u8 {
    return current.allocateTrampolinePage(address_hint, kind);
}

/// Releases a trampoline page previously returned by
/// `allocateTrampolinePage(...)`.
pub fn freeTrampolinePage(trampoline_pc: u64) void {
    current.freeTrampolinePage(trampoline_pc);
}
