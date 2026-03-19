//! Public zighook API.
//!
//! `zighook` is an experimental runtime instrumentation library for the first
//! completed backend slice:
//! - OS: macOS
//! - Architecture: AArch64 / Apple Silicon
//!
//! The caller-facing design is intentionally small and entirely centered around
//! `sigaction`-driven trap handling:
//! - `instrument(...)`: trap one instruction and then execute it
//! - `instrument_no_original(...)`: trap one instruction and replace it
//! - `inline_hook(...)`: trap a function entry and return directly to the caller
//! - `prepatched.*`: the same semantics for binaries that already contain `brk`
//!
//! This file is meant to be the primary integration guide. Application code
//! should normally not need to read the internal backend modules in order to
//! install and use hooks correctly.

const builtin = @import("builtin");
const std = @import("std");

comptime {
    const supported_os = switch (builtin.os.tag) {
        .macos, .ios, .linux => true,
        else => false,
    };

    if (!supported_os or builtin.cpu.arch != .aarch64) {
        @compileError("zighook currently implements AArch64 backends for macOS, iOS, Linux, and Android (Linux OS tag with Android ABI).");
    }
}

const memory = @import("memory.zig");
const signal = @import("signal.zig");
const state = @import("state.zig");
const aarch64 = @import("arch/aarch64.zig");

/// Public error set returned by hook installation, lookup, and removal APIs.
///
/// In practice, most callers should expect a small subset of failures:
/// - `error.InvalidAddress`: null, misaligned, or otherwise unusable address
/// - `error.ReplayUnsupported`: execute-original replay is not safe for that opcode
/// - `error.HookSlotsFull`: the fixed-size runtime registry has no free entry
/// - `error.HookNotFound`: `unhook(...)` was asked to remove an unknown address
/// - `error.UnsupportedOperation`: usually means a prepatched workflow is
///   missing cached original opcode metadata
pub const HookError = @import("error.zig").HookError;

/// Stable AArch64 register snapshot exposed to every callback.
///
/// The general-purpose register bank offers two equivalent views:
/// - `ctx.regs.x[0] ... ctx.regs.x[30]`
/// - `ctx.regs.named.x0 ... ctx.regs.named.x30`
///
/// The SIMD / floating-point bank follows the architectural `vN` names and is
/// also exposed as both indexed and named unions:
/// - `ctx.fpregs.v[0] ... ctx.fpregs.v[31]`
/// - `ctx.fpregs.named.v0 ... ctx.fpregs.named.v31`
///
/// The stored value is always the full 128-bit `vN` register contents. When a
/// callback wants to emulate `sN` or `dN`, it typically writes the low 32 or
/// low 64 bits of the corresponding `vN`.
pub const HookContext = aarch64.HookContext;

/// C-callable callback type used by all public hook installers.
///
/// Parameters:
/// - `address`: the trapped instruction address
/// - `ctx`: mutable live register state that will be written back on success
///
/// Control-flow rule:
/// - if the callback overwrites `ctx.pc`, zighook respects that decision
/// - otherwise the selected API decides how execution resumes
pub const InstrumentCallback = aarch64.InstrumentCallback;

/// Dual-view container for AArch64 general-purpose registers `x0..x30`.
pub const XRegisters = aarch64.XRegisters;

/// Named AArch64 general-purpose register view (`x0..x30`).
pub const XRegistersNamed = aarch64.XRegistersNamed;

/// Dual-view container for AArch64 SIMD / floating-point registers `v0..v31`.
pub const FpRegisters = aarch64.FpRegisters;

/// Named AArch64 SIMD / floating-point register view (`v0..v31`).
pub const FpRegistersNamed = aarch64.FpRegistersNamed;

/// How a trap-based API discovers the original instruction bytes it should
/// remember and, optionally, replay.
const InstallMode = enum {
    /// zighook patches the executable page at registration time.
    runtime_patch,
    /// the caller already arranged for `brk` to be present in the binary.
    prepatched,
};

/// Installs a trap on the instruction at `address` and replays the displaced
/// instruction after `callback` returns.
///
/// This is the API to use when the original instruction must still run, but
/// you want to inspect or edit machine state immediately before that happens.
///
/// Installation contract:
/// - `address` must point to a 4-byte aligned AArch64 instruction
/// - zighook replaces that instruction with `brk #0`
/// - the original opcode is returned to the caller and cached internally
/// - signal handlers are installed lazily on the first successful hook
///
/// Resume behavior:
/// - if `callback` overwrites `ctx.pc`, that explicit control-flow choice wins
/// - otherwise zighook replays the displaced instruction
/// - after replay, execution continues at the following instruction
///
/// Execute-original mode is intentionally strict. Installation fails before
/// patching code unless zighook can prove a safe replay strategy for the
/// trapped opcode.
///
/// This function returns the original 32-bit instruction word.
///
/// Example:
/// ```zig
/// const zighook = @import("zighook");
/// const c = @cImport({
///     @cInclude("dlfcn.h");
/// });
///
/// fn onAdd(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
///     ctx.regs.named.x0 = 40;
///     ctx.regs.named.x1 = 2;
/// }
///
/// fn install() void {
///     const symbol = c.dlsym(c.RTLD_DEFAULT, "target_add_patchpoint");
///     if (symbol != null) {
///         _ = zighook.instrument(@intFromPtr(symbol.?), onAdd) catch {};
///     }
/// }
/// ```
pub fn instrument(address: u64, callback: InstrumentCallback) HookError!u32 {
    return instrumentInternal(address, callback, true, false, .runtime_patch);
}

/// Installs a trap on the instruction at `address` and skips the displaced
/// instruction unless the callback explicitly redirects control flow.
///
/// This is the replacement-style API. Use it when the callback fully emulates
/// the trapped instruction or wants to synthesize a different result.
///
/// Resume behavior:
/// - if `callback` overwrites `ctx.pc`, that explicit control-flow choice wins
/// - otherwise zighook advances to the next instruction without replaying the
///   displaced opcode
///
/// This function still returns the original 32-bit instruction word, which can
/// be useful for logging or for later offline patch preparation.
///
/// Example:
/// ```zig
/// const zighook = @import("zighook");
/// const c = @cImport({
///     @cInclude("dlfcn.h");
/// });
///
/// fn onHit(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
///     ctx.regs.named.x0 = 99;
/// }
///
/// fn install() void {
///     const symbol = c.dlsym(c.RTLD_DEFAULT, "target_add_patchpoint");
///     if (symbol != null) {
///         _ = zighook.instrument_no_original(@intFromPtr(symbol.?), onHit) catch {};
///     }
/// }
/// ```
pub fn instrument_no_original(address: u64, callback: InstrumentCallback) HookError!u32 {
    return instrumentInternal(address, callback, false, false, .runtime_patch);
}

/// Hooks a function entry by replacing its first instruction with `brk #0`.
///
/// This is the "return directly from the callback" API. It is typically used
/// at function entry points where the callback wants to produce a synthetic
/// return value and skip the callee body entirely.
///
/// Resume behavior:
/// - if `callback` overwrites `ctx.pc`, that explicit control-flow choice wins
/// - otherwise zighook returns to `lr`, as if the function had completed
///
/// Typical usage:
/// - write the desired return value into `ctx.regs.named.x0`
/// - optionally adjust other registers for side effects
/// - leave `ctx.pc` untouched so zighook returns to the caller automatically
///
/// This function returns the original 32-bit instruction word that was replaced
/// by the trap.
///
/// Example:
/// ```zig
/// const zighook = @import("zighook");
/// const c = @cImport({
///     @cInclude("dlfcn.h");
/// });
///
/// fn onEnter(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
///     ctx.regs.named.x0 = 42;
/// }
///
/// fn install() void {
///     const symbol = c.dlsym(c.RTLD_DEFAULT, "target_add");
///     if (symbol != null) {
///         _ = zighook.inline_hook(@intFromPtr(symbol.?), onEnter) catch {};
///     }
/// }
/// ```
pub fn inline_hook(address: u64, callback: InstrumentCallback) HookError!u32 {
    return instrumentInternal(address, callback, false, true, .runtime_patch);
}

/// Removes a previously registered hook.
///
/// Behavior depends on how the address was installed:
/// - runtime patch APIs restore the original code bytes
/// - `prepatched.*` APIs remove dispatch state only and leave the existing
///   `brk` instruction in place
///
/// This call is not idempotent. If no hook exists for `address`, it returns
/// `error.HookNotFound`.
///
/// Example:
/// ```zig
/// const zighook = @import("zighook");
///
/// fn removePatchpoint(address: u64) void {
///     zighook.unhook(address) catch |err| switch (err) {
///         error.HookNotFound => {},
///         else => {},
///     };
/// }
/// ```
pub fn unhook(address: u64) HookError!void {
    if (state.slotByAddress(address)) |slot| {
        if (slot.runtime_patch_installed) {
            try memory.patchBytes(address, slot.original_bytes[0..slot.original_len]);
        }

        if (state.removeHook(address)) |removed_slot| {
            if (removed_slot.trampoline_pc != 0) {
                aarch64.freeOriginalTrampoline(removed_slot.trampoline_pc);
            }
        }

        _ = state.removeCachedOriginalOpcode(address);
        return;
    }
    return error.HookNotFound;
}

/// Returns the known original 32-bit instruction word for `address`, if one is
/// currently cached.
///
/// Lookup sources:
/// - a live trap hook slot created by `instrument*` or `inline_hook`
/// - explicit metadata stored with `prepatched.cache_original_opcode(...)`
///
/// This is useful when higher-level tooling wants to inspect or log the opcode
/// without reaching into internal registries.
///
/// Example:
/// ```zig
/// const zighook = @import("zighook");
///
/// fn logOpcode(address: u64) void {
///     if (zighook.original_opcode(address)) |opcode| {
///         _ = opcode;
///     }
/// }
/// ```
pub fn original_opcode(address: u64) ?u32 {
    return state.cachedOriginalOpcode(address) orelse
        state.hookOriginalOpcode(address);
}

/// CamelCase alias kept for callers that prefer the Rust crate naming.
pub const originalOpcode = original_opcode;

/// APIs for trap points that already contain `brk` before process startup.
///
/// This namespace is intended for offline patching workflows:
/// - the binary was edited ahead of time
/// - or another build step already emitted `brk` at known patch points
/// - zighook only needs to register runtime dispatch state
///
/// `prepatched.inline_hook(...)` does not require extra metadata because it
/// never needs to replay the displaced instruction.
///
/// `prepatched.instrument(...)` does require the original opcode. Call
/// `prepatched.cache_original_opcode(...)` before registration so zighook knows
/// what it must replay when the trap fires.
pub const prepatched = struct {
    /// Registers an already-trapped instruction and replays the displaced
    /// original opcode after the callback returns.
    ///
    /// Requirements:
    /// - the executable page at `address` must already contain `brk`
    /// - `prepatched.cache_original_opcode(address, opcode)` must have been
    ///   called earlier with the displaced original instruction word
    ///
    /// Example:
    /// ```zig
    /// const zighook = @import("zighook");
    ///
    /// fn installPrepatched(address: u64, original_opcode: u32, callback: zighook.InstrumentCallback) void {
    ///     zighook.prepatched.cache_original_opcode(address, original_opcode) catch {};
    ///     _ = zighook.prepatched.instrument(address, callback) catch {};
    /// }
    /// ```
    pub fn instrument(address: u64, callback: InstrumentCallback) HookError!u32 {
        return instrumentInternal(address, callback, true, false, .prepatched);
    }

    /// Registers an already-trapped instruction and skips the displaced
    /// original opcode unless the callback redirects `ctx.pc`.
    ///
    /// This is the prepatched equivalent of `instrument_no_original(...)`.
    pub fn instrument_no_original(address: u64, callback: InstrumentCallback) HookError!u32 {
        return instrumentInternal(address, callback, false, false, .prepatched);
    }

    /// Registers an already-trapped function entry hook.
    ///
    /// This is the prepatched equivalent of `inline_hook(...)`. Because the
    /// callback returns directly to the caller by default, no cached original
    /// opcode is required.
    pub fn inline_hook(address: u64, callback: InstrumentCallback) HookError!u32 {
        return instrumentInternal(address, callback, false, true, .prepatched);
    }

    /// Stores the original instruction word for a prepatched trap point.
    ///
    /// Call this before `prepatched.instrument(...)` whenever execute-original
    /// replay is needed. The text page already contains `brk`, so zighook
    /// cannot recover the displaced instruction by reading process memory.
    ///
    /// Example:
    /// ```zig
    /// const zighook = @import("zighook");
    ///
    /// fn rememberOriginal(address: u64, opcode: u32) void {
    ///     zighook.prepatched.cache_original_opcode(address, opcode) catch {};
    /// }
    /// ```
    pub fn cache_original_opcode(address: u64, opcode: u32) HookError!void {
        if (address == 0 or (address & 0b11) != 0) return error.InvalidAddress;
        state.cacheOriginalOpcode(address, opcode);
    }
};

/// Ensures that a `prepatched::*` registration really points at a trap site.
fn ensurePrepatchedTrap(address: u64) HookError!void {
    const opcode = try memory.readU32(address);
    if (!aarch64.isBrk(opcode)) return error.InvalidAddress;
}

fn instrumentInternal(
    address: u64,
    callback: InstrumentCallback,
    execute_original: bool,
    return_to_caller: bool,
    install_mode: InstallMode,
) HookError!u32 {
    const replay_plan = if (execute_original)
        try planExecuteOriginalReplay(address)
    else
        aarch64.ReplayPlan{ .skip = {} };

    if (state.slotByAddress(address)) |slot| {
        // Re-registering the same address updates callback policy in-place.
        try state.registerHook(
            address,
            slot.original_bytes[0..slot.original_len],
            slot.step_len,
            callback,
            execute_original,
            return_to_caller,
            install_mode == .runtime_patch,
            replay_plan,
        );

        return state.cachedOriginalOpcode(address) orelse
            state.hookOriginalOpcode(address) orelse
            error.InvalidAddress;
    }

    try signal.ensureHandlersInstalled();

    const step_len = try aarch64.instructionWidth(address);

    var original_bytes_storage: [4]u8 = undefined;
    var saved_opcode: u32 = undefined;
    var runtime_patch_installed = false;

    switch (install_mode) {
        .runtime_patch => {
            // Replace the target instruction with `brk` immediately and keep
            // the original opcode for replay or later restoration.
            saved_opcode = try memory.patchU32(address, aarch64.brk_opcode);
            original_bytes_storage = std.mem.toBytes(std.mem.nativeToLittle(u32, saved_opcode));
            runtime_patch_installed = true;
        },
        .prepatched => {
            // The binary already contains `brk`, so registration is bookkeeping
            // only. For execute-original mode the caller must have cached the
            // displaced instruction ahead of time.
            try ensurePrepatchedTrap(address);

            if (execute_original) {
                saved_opcode = state.cachedOriginalOpcode(address) orelse return error.UnsupportedOperation;
                original_bytes_storage = std.mem.toBytes(std.mem.nativeToLittle(u32, saved_opcode));
            } else {
                saved_opcode = try memory.readU32(address);
                original_bytes_storage = std.mem.toBytes(std.mem.nativeToLittle(u32, saved_opcode));
            }
        },
    }

    state.registerHook(
        address,
        original_bytes_storage[0..],
        step_len,
        callback,
        execute_original,
        return_to_caller,
        runtime_patch_installed,
        replay_plan,
    ) catch |err| {
        if (runtime_patch_installed) {
            _ = memory.patchU32(address, saved_opcode) catch {};
        }
        return err;
    };

    if (runtime_patch_installed) {
        state.cacheOriginalOpcode(address, saved_opcode);
    }
    return saved_opcode;
}

/// Decides how `instrument(...)` should execute the displaced instruction.
///
/// The decision is made before runtime state is registered so unsupported
/// execute-original cases fail early, before any executable page is modified.
fn planExecuteOriginalReplay(address: u64) HookError!aarch64.ReplayPlan {
    const opcode = state.cachedOriginalOpcode(address) orelse try memory.readU32(address);
    return aarch64.planReplay(address, opcode);
}
