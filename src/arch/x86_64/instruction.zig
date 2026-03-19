//! Minimal x86_64 replay interface.
//!
//! The first x86_64 backend slice does not implement execute-original replay
//! yet. The public trap APIs are still wired through the same internal shape so
//! the higher layers can share registry and dispatch logic.

const HookError = @import("../../error.zig").HookError;
const HookContext = @import("context/root.zig").HookContext;

pub const ReplayPlan = union(enum) {
    skip: void,

    pub fn requiresTrampoline(_: ReplayPlan) bool {
        return false;
    }
};

pub fn planReplay(_: u64, _: u32) HookError!ReplayPlan {
    return error.ReplayUnsupported;
}

pub fn applyReplay(_: ReplayPlan, _: u64, _: *HookContext) HookError!void {
    return error.ReplayUnsupported;
}
