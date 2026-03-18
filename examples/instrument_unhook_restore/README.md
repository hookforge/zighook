# instrument_unhook_restore

This example shows that `zighook.unhook(...)` restores the original code bytes
for a runtime-installed trap hook.

The hook library installs `instrument_no_original(...)` on a single `add`
instruction and exports a helper named `zighook_example_unhook`. The target
program calls the target function once while hooked, resolves that helper with
`dlsym`, invokes it, and calls the target again after restoration.

## Build

```bash
cc -arch arm64 -O3 -DNDEBUG -Wl,-export_dynamic -o target target.c
```

```bash
zig build-lib -dynamic -OReleaseFast -femit-bin=hook.dylib \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  -lc
```

## Run

```bash
DYLD_INSERT_LIBRARIES=$PWD/hook.dylib ./target
```

## Expected Output

```text
hooked=123
restored=5
```
