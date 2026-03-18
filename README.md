# zighook

`zighook` is a Zig rewrite of the sibling Rust `sighook` project.

Current scope:

- macOS
- Apple Silicon / AArch64

Implemented APIs:

- `patchcode(address, opcode)`
- `patch_bytes(allocator, address, bytes)`
- `instrument(address, callback)`
- `instrument_no_original(address, callback)`
- `inline_hook(address, callback)`
- `inline_hook_jump(address, replace_fn)`
- `unhook(address)`
- `original_opcode(address)`
- `prepatched.instrument*`
- `prepatched.inline_hook`
- `prepatched.cache_original_opcode`

The current backend supports:

- direct instruction patching
- trap-based instrumentation via `brk`
- signal-based entry hooks
- jump detours
- constructor-based dylib payloads for `DYLD_INSERT_LIBRARIES` / later Mach-O insertion workflows

## Status

This repository currently targets the first backend slice only:

- `aarch64-apple-darwin`

It is usable for local experiments on Apple Silicon macOS, but it is not yet at full feature/platform parity with the Rust crate.

## Build

```bash
zig build
zig build test
zig build examples
```

## Preload Smoke Tests

The repository includes dylib payloads and a small C target to validate constructor-based preload hooking:

```bash
zig build preload-smoke
```

This builds and runs:

- `libzighook_payload_inline_hook_signal.dylib`
- `libzighook_payload_inline_hook_jump.dylib`
- `zighook_preload_target_add`

Manual preload usage after `zig build`:

```bash
DYLD_INSERT_LIBRARIES=zig-out/lib/libzighook_payload_inline_hook_signal.dylib \
TARGET_EXPECT=42 \
zig-out/bin/zighook_preload_target_add
```

```bash
DYLD_INSERT_LIBRARIES=zig-out/lib/libzighook_payload_inline_hook_jump.dylib \
TARGET_EXPECT=6 \
zig-out/bin/zighook_preload_target_add
```

## Examples

See:

- `examples/README.md`
- `examples/preload/README.md`

## License

This repository follows the same license file as the Rust `sighook` repository.
See `LICENSE`.
