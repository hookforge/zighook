//! Architecture-neutral trap-dispatch policy.
//!
//! Platform trap backends recover native thread state and then delegate here to
//! apply zighook's public callback contract:
//! - explicit `ctx.pc` edits always win
//! - `inline_hook(...)` returns to the caller when the callback leaves `pc`
//!   untouched
//! - `instrument(...)` either jumps to a trampoline or applies an ISA-specific
//!   semantic replay plan
//! - `instrument_no_original(...)` skips to the next instruction

const arch = @import("../arch/root.zig");
const state = @import("../state.zig");

/// Applies the runtime hook policy for a trapped instruction.
///
/// Returns `true` when zighook recognized the address and updated `ctx` with a
/// valid resume state. Returns `false` when the trap should be forwarded to the
/// platform's previous handler chain.
///
/// Dispatch order:
/// 1. find the hook slot for `address`
/// 2. invoke the user callback with the stable ISA-specific `HookContext`
/// 3. honor an explicit `ctx.pc` overwrite immediately
/// 4. otherwise apply the selected API policy:
///    - `inline_hook(...)`: synthesize a return to the caller
///    - `instrument(...)`: execute the original instruction by replay plan
///    - `instrument_no_original(...)`: skip to the next instruction
pub fn handleTrap(address: u64, ctx: *arch.HookContext) bool {
    const slot = state.slotByAddress(address) orelse return false;
    const callback = slot.callback orelse return false;

    const original_pc = ctx.pc;
    callback(address, ctx);

    if (ctx.pc != original_pc) return true;

    if (slot.return_to_caller) {
        // `inline_hook(...)` conceptually replaces the entire callee with the
        // callback. If the callback leaves `pc` untouched, zighook completes
        // the ABI-level return on its behalf.
        arch.returnToCaller(ctx) catch return false;
        return true;
    }

    const next_pc = address + slot.step_len;
    if (slot.execute_original) {
        if (slot.replay_plan.requiresTrampoline()) {
            // Variable-length or relocation-sensitive instructions may need an
            // out-of-line trampoline rather than a purely semantic register
            // rewrite. In that case the trampoline address becomes the next PC.
            ctx.pc = slot.trampoline_pc;
        } else {
            arch.applyReplay(slot.replay_plan, address, ctx) catch return false;
        }
    } else {
        ctx.pc = next_pc;
    }
    return true;
}
