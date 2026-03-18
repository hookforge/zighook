# instrument_with_original

This example traps one instruction and then replays it with edited registers by
using `zighook.instrument(...)`.

The callback rewrites `x0 = 40` and `x1 = 2` before the trapped `add`
instruction executes, so the final program result becomes `42`.

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
result=42
```
