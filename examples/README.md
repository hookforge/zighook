# zighook examples

These examples mirror the intent of the Rust `sighook` demos, but are currently
implemented only for the first completed backend slice:

- **OS:** macOS
- **Architecture:** Apple Silicon / AArch64

Build every example executable:

```bash
zig build examples
```

Available examples:

- `patchcode_add_to_mul`: patch one AArch64 instruction directly
- `instrument_with_original`: trap one instruction, mutate registers, then replay it
- `instrument_no_original`: trap one instruction and emulate / replace it in the callback
- `inline_hook_signal`: trap a function entry and return directly from the callback
- `inline_hook_jump`: direct branch-based detour (equivalent in intent to the Rust `inline_hook_far` example)
- `instrument_unhook_restore`: install a trap hook and then verify that `unhook` restores normal behavior
- `preload/`: constructor-based dylib payloads plus a small C target for `DYLD_INSERT_LIBRARIES` smoke testing

Build the DYLD payloads and C target:

```bash
zig build preload-examples
```

Run the preload smoke tests:

```bash
zig build preload-smoke
```

Not yet ported from the Rust crate:

- `patch_asm_add_to_mul` (requires an assembler helper that zighook does not expose yet)
- `instrument_adrp_no_original` (depends on a dedicated ADRP demo target and instruction decoder)
