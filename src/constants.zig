//! Backend constants shared across the runtime patching modules.

/// Maximum number of active entries in each fixed-size runtime registry.
pub const max_hooks = 256;

/// Maximum amount of original instruction bytes cached per address.
///
/// The current backend only needs 4 or 16 bytes depending on the operation, but
/// keeping the storage at 16 bytes mirrors the Rust implementation and leaves
/// enough room for far jump restoration.
pub const max_saved_bytes = 16;
