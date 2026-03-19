# inline_hook_signal

This example installs a function-entry hook with `zighook.inline_hook(...)`.

The target program exports a tiny `target_add` function:

- on AArch64 it returns through `x0`
- on x86_64 it returns through `rax`

The hook library resolves `target_add` with `dlsym` and replaces the call
result inside the callback.

## Build

Build the C target in release mode:

```bash
cc -arch arm64 -O3 -DNDEBUG -Wl,-export_dynamic -o target target.c
```

Linux x86_64 CI uses the corresponding native ELF build:

```bash
cc -O3 -DNDEBUG -rdynamic -o target target.c -ldl
```

Build the Zig hook library in release mode:

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

Linux x86_64:

```bash
LD_PRELOAD=$PWD/hook.so ./target
```

## Expected Output

```text
result=42
```
