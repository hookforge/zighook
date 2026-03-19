//! Public zighook API.
//!
//! `zighook` is an experimental runtime instrumentation library for
//! signal-driven inline hooks and instruction hooks.
//!
//! The caller-facing design is intentionally small and entirely centered around
//! `sigaction`-driven trap handling:
//! - `instrument(...)`: trap one instruction and then execute it
//! - `instrument_no_original(...)`: trap one instruction and replace it
//! - `inline_hook(...)`: trap a function entry and return directly to the caller
//! - `prepatched.*`: the same semantics for binaries that already contain a trap
//!
//! This file is meant to be the primary integration guide. Application code
//! should normally not need to read the internal backend modules in order to
//! install and use hooks correctly.

const builtin = @import("builtin");
const std = @import("std");

comptime {
    const supported = switch (builtin.cpu.arch) {
        .aarch64 => switch (builtin.os.tag) {
            .macos, .ios, .linux => true,
            else => false,
        },
        .x86_64 => switch (builtin.os.tag) {
            .macos, .linux => true,
            else => false,
        },
        else => false,
    };

    if (!supported) {
        @compileError("zighook currently implements AArch64 backends for macOS, iOS, Linux, and Android, plus x86_64 backends for macOS and Linux.");
    }
}

const memory = @import("memory.zig");
const SavedInstruction = @import("saved_instruction.zig").SavedInstruction;
const signal = @import("signal.zig");
const state = @import("state.zig");
const arch = @import("arch/root.zig");

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

/// Stable architecture-specific register snapshot exposed to every callback.
///
/// The exact field names depend on the selected target architecture at compile
/// time. For example:
/// - AArch64 exposes `x0..x30` and `v0..v31`
/// - x86_64 exposes `rax..r15` and `xmm0..xmm15`
pub const HookContext = arch.HookContext;

/// C-callable callback type used by all public hook installers.
///
/// Parameters:
/// - `address`: the trapped instruction address
/// - `ctx`: mutable live register state that will be written back on success
///
/// Control-flow rule:
/// - if the callback overwrites `ctx.pc`, zighook respects that decision
/// - otherwise the selected API decides how execution resumes
pub const InstrumentCallback = arch.InstrumentCallback;

/// Dual-view container for architecture-specific general-purpose registers.
pub const GpRegisters = arch.GpRegisters;

/// Named architecture-specific general-purpose register view.
pub const GpRegistersNamed = arch.GpRegistersNamed;

/// Compatibility alias kept for the original AArch64-first public API.
pub const XRegisters = arch.XRegisters;

/// Compatibility alias kept for the original AArch64-first public API.
pub const XRegistersNamed = arch.XRegistersNamed;

/// Dual-view container for architecture-specific SIMD / floating-point registers.
pub const FpRegisters = arch.FpRegisters;

/// Named architecture-specific SIMD / floating-point register view.
pub const FpRegistersNamed = arch.FpRegistersNamed;

/// Byte-oriented representation of a displaced original instruction.
pub const OriginalInstruction = SavedInstruction;

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
                arch.freeOriginalTrampoline(removed_slot.trampoline_pc);
            }
        }

        _ = state.removeCachedOriginalInstruction(address);
        return;
    }
    return error.HookNotFound;
}

/// Returns the known original instruction bytes for `address`, if any are
/// currently cached.
///
/// Lookup sources:
/// - a live trap hook slot created by `instrument*` or `inline_hook`
/// - explicit metadata stored with `cache_original_instruction(...)`
///
/// Variable-length ISAs should prefer this API over `original_opcode(...)`.
pub fn original_instruction(address: u64) ?OriginalInstruction {
    return state.cachedOriginalInstruction(address) orelse
        state.hookOriginalInstruction(address);
}

/// CamelCase alias kept for callers that prefer the Rust crate naming.
pub const originalInstruction = original_instruction;

/// Returns the known original 32-bit instruction word for `address`, if the
/// current ISA uses fixed-width 32-bit instructions.
pub fn original_opcode(address: u64) ?u32 {
    if (!arch.supportsPatchCode()) return null;
    const instruction = original_instruction(address) orelse return null;
    return instruction.exactU32();
}

/// CamelCase alias kept for callers that prefer the Rust crate naming.
pub const originalOpcode = original_opcode;

/// Writes arbitrary bytes into executable memory.
pub fn patch_bytes(address: u64, bytes: []const u8) HookError!void {
    return memory.patchBytes(address, bytes);
}

/// CamelCase alias kept for callers that prefer the Rust crate naming.
pub const patchBytes = patch_bytes;

/// Writes a fixed-width 32-bit instruction word into executable memory.
///
/// This helper is only meaningful on backends whose instruction encoding model
/// is naturally expressed as a 32-bit word, such as AArch64.
pub fn patch_code(address: u64, opcode: u32) HookError!u32 {
    if (!arch.supportsPatchCode()) return error.UnsupportedOperation;
    return memory.patchU32(address, opcode);
}

/// CamelCase alias kept for callers that prefer the Rust crate naming.
pub const patchCode = patch_code;

/// Records original instruction bytes for later `prepatched.*` registration or
/// for variable-length ISA instruction hooks that need an explicit step length.
pub fn cache_original_instruction(address: u64, bytes: []const u8) HookError!void {
    return cacheOriginalInstructionImpl(address, bytes);
}

fn cacheOriginalInstructionImpl(address: u64, bytes: []const u8) HookError!void {
    try arch.validateAddress(address);
    state.cacheOriginalInstruction(address, try SavedInstruction.fromSlice(bytes));
}

/// CamelCase alias kept for callers that prefer the Rust crate naming.
pub const cacheOriginalInstruction = cache_original_instruction;

/// APIs for trap points that already contain a trap instruction before process startup.
///
/// This namespace is intended for offline patching workflows:
/// - the binary was edited ahead of time
/// - or another build step already emitted `brk` at known patch points
/// - zighook only needs to register runtime dispatch state
///
/// `prepatched.inline_hook(...)` does not require extra metadata because it
/// never needs to replay the displaced instruction.
///
/// `prepatched.instrument(...)` does require the original instruction bytes.
/// Call `cache_original_instruction(...)` or
/// `prepatched.cache_original_instruction(...)` before registration so zighook
/// knows what it must replay or skip when the trap fires.
pub const prepatched = struct {
    /// Registers an already-trapped instruction and replays the displaced
    /// original opcode after the callback returns.
    ///
    /// Requirements:
    /// - the executable page at `address` must already contain a trap
    /// - `cache_original_instruction(...)` must have been called earlier with
    ///   the displaced original instruction bytes
    ///
    /// Example:
    /// ```zig
    /// const zighook = @import("zighook");
    ///
    /// fn installPrepatched(address: u64, original_bytes: []const u8, callback: zighook.InstrumentCallback) void {
    ///     zighook.prepatched.cache_original_instruction(address, original_bytes) catch {};
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
    /// instruction is required.
    pub fn inline_hook(address: u64, callback: InstrumentCallback) HookError!u32 {
        return instrumentInternal(address, callback, false, true, .prepatched);
    }

    /// Stores the original instruction bytes for a prepatched trap point.
    ///
    /// Call this before `prepatched.instrument(...)` whenever execute-original
    /// replay or instruction skipping is needed on a backend that cannot infer
    /// instruction length from the patched bytes alone. The text page already
    /// contains a trap, so zighook
    /// cannot recover the displaced instruction by reading process memory.
    pub fn cache_original_instruction(address: u64, bytes: []const u8) HookError!void {
        return cacheOriginalInstructionImpl(address, bytes);
    }

    /// Stores the original fixed-width 32-bit instruction word for a
    /// prepatched trap point.
    pub fn cache_original_opcode(address: u64, opcode: u32) HookError!void {
        if (!arch.supportsPatchCode()) return error.UnsupportedOperation;
        const opcode_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, opcode));
        return cacheOriginalInstructionImpl(address, opcode_bytes[0..]);
    }
};

/// Ensures that a `prepatched::*` registration really points at a trap site.
fn ensurePrepatchedTrap(address: u64) HookError!void {
    if (!(try arch.isTrapInstruction(address))) return error.InvalidAddress;
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
        arch.ReplayPlan{ .skip = {} };

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

        return currentOriginalInstructionPrefix(address) orelse error.InvalidAddress;
    }

    try signal.ensureHandlersInstalled();
    try arch.validateAddress(address);

    var cached_instruction = state.cachedOriginalInstruction(address);
    const step_len = try resolveStepLen(address, return_to_caller, cached_instruction);
    var restore_instruction: SavedInstruction = undefined;
    var runtime_patch_installed = false;

    switch (install_mode) {
        .runtime_patch => {
            restore_instruction = try readInstructionBytes(address, arch.trapPatchBytes().len);
            try memory.patchBytes(address, arch.trapPatchBytes());
            if (cached_instruction == null) {
                cached_instruction = restore_instruction;
            }
            runtime_patch_installed = true;
        },
        .prepatched => {
            try ensurePrepatchedTrap(address);
            restore_instruction = try readInstructionBytes(address, arch.trapPatchBytes().len);
            if (cached_instruction == null) {
                cached_instruction = restore_instruction;
            }
        },
    }

    state.registerHook(
        address,
        restore_instruction.slice(),
        step_len,
        callback,
        execute_original,
        return_to_caller,
        runtime_patch_installed,
        replay_plan,
    ) catch |err| {
        if (runtime_patch_installed) {
            _ = memory.patchBytes(address, restore_instruction.slice()) catch {};
        }
        return err;
    };

    if (cached_instruction) |instruction| {
        state.cacheOriginalInstruction(address, instruction);
    }
    return currentOriginalInstructionPrefix(address) orelse error.InvalidAddress;
}

/// Decides how `instrument(...)` should execute the displaced instruction.
///
/// The decision is made before runtime state is registered so unsupported
/// execute-original cases fail early, before any executable page is modified.
fn planExecuteOriginalReplay(address: u64) HookError!arch.ReplayPlan {
    if (!arch.supportsPatchCode()) return error.ReplayUnsupported;

    const opcode = if (state.cachedOriginalInstruction(address)) |instruction|
        instruction.exactU32() orelse return error.UnsupportedOperation
    else
        try memory.readU32(address);

    return arch.planReplay(address, opcode);
}

fn resolveStepLen(address: u64, return_to_caller: bool, saved_instruction: ?SavedInstruction) HookError!u8 {
    switch (builtin.cpu.arch) {
        .aarch64 => return arch.instructionWidth(address),
        .x86_64 => {
            if (return_to_caller) return 1;
            const instruction = saved_instruction orelse return error.UnsupportedOperation;
            return instruction.len;
        },
        else => return error.UnsupportedArchitecture,
    }
}

fn readInstructionBytes(address: u64, len: usize) HookError!SavedInstruction {
    var bytes = [_]u8{0} ** 16;
    try memory.readInto(address, bytes[0..len]);
    return SavedInstruction.fromSlice(bytes[0..len]);
}

fn currentOriginalInstructionPrefix(address: u64) ?u32 {
    const instruction = original_instruction(address) orelse return null;
    return instruction.prefixU32();
}
