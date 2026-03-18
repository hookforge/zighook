# DYLD preload smoke examples

These files mirror the Rust crate's constructor-based payload flow more closely
than the plain executable demos.

Artifacts:

- `libzighook_payload_inline_hook_signal.dylib`
- `libzighook_payload_inline_hook_jump.dylib`
- `zighook_preload_target_add`

Build them:

```bash
zig build preload-examples
```

Run the automatic smoke tests:

```bash
zig build preload-smoke
```

Manual usage after `zig build install`:

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

Because the payloads are normal dylibs with constructor sections, they can also
be used in later `insert_dylib` / Mach-O rewriting workflows.
