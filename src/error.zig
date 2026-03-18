//! Error set shared by the public API and the internal backend.
//!
//! The current rewrite deliberately keeps the error surface compact. Most low-level
//! platform failures are mapped into a small set of semantic failures that remain
//! stable as the backend evolves.

/// Errors that can be returned by the public hook APIs.
pub const HookError = error{
    /// The supplied address is null, misaligned, or otherwise unusable for the
    /// requested operation.
    InvalidAddress,

    /// The current operating system backend has not been implemented yet.
    UnsupportedPlatform,

    /// The current CPU architecture backend has not been implemented yet.
    UnsupportedArchitecture,

    /// The request is valid in general, but not supported by the currently
    /// implemented backend or by the selected installation mode.
    UnsupportedOperation,

    /// The fixed-size direct patch registry is full.
    PatchSlotsFull,

    /// The fixed-size instrumentation registry is full.
    HookSlotsFull,

    /// No runtime patch or hook state exists for the specified address.
    HookNotFound,

    /// A near branch encoding cannot reach the requested destination.
    BranchOutOfRange,

    /// `instrument(...)` was asked to execute the original instruction, but the
    /// current backend could not prove a safe replay strategy for that opcode.
    ReplayUnsupported,

    /// The trapped instruction would require floating-point / SIMD state that a
    /// given backend or installation mode does not currently remap.
    FloatingPointContextUnavailable,

    /// Changing page protections for executable memory failed.
    PageProtectionChangeFailed,

    /// Preparing a signal mask failed while installing handlers.
    SignalMaskInitFailed,

    /// Registering a signal handler with `sigaction` failed.
    SignalHandlerInstallFailed,

    /// The signal handler did not receive a context shape that matches the
    /// backend assumptions.
    UnexpectedSignalContext,

    /// Allocating executable trampoline memory failed.
    TrampolineAllocationFailed,

    /// Converting trampoline memory from RW to RX failed.
    TrampolineProtectFailed,

    /// Heap allocation failed in the non-signal path.
    OutOfMemory,
};
