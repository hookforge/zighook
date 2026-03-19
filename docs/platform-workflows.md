# AArch64 platform workflows

This repository now implements AArch64 backends for:

- macOS
- iOS
- Linux
- Android

The core trap/replay engine is shared across all of them. The platform-specific
differences are mostly:

- how executable pages are patched
- how `sigaction` / `ucontext_t` machine state is remapped
- how the sidecar payload is injected into the target process

The example `hook.zig` payloads automatically pick the right constructor
section:

- Mach-O (`macOS`, `iOS`): `__DATA,__mod_init_func`
- ELF (`Linux`, `Android`): `.init_array`

## Linux AArch64

Recommended workflows:

- `LD_PRELOAD` for local experiments
- `patchelf` for persistent sidecar loading

Build a sidecar payload from any example directory:

```bash
cc -O3 -DNDEBUG -Wl,-export-dynamic -o target target.c

zig build-lib -dynamic -target aarch64-linux-musl -OReleaseFast -femit-bin=hook.so \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  -lc
```

Run with preload:

```bash
LD_PRELOAD=$PWD/hook.so ./target
```

Or patch the ELF loader metadata with `patchelf` / equivalent tooling and ship
the sidecar `.so` next to the target binary.

## iOS AArch64

Recommended workflow:

- use `prepatched.*`
- patch `brk #0` into the app binary offline
- ship a sidecar dylib inside `Frameworks/`
- inject the load command with `insert-dylib`
- re-sign the entire app bundle and install

`prepatched_inline_hook` is the best template example for this deployment mode.

Build the payload dylib:

```bash
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)

zig build-lib -dynamic -target aarch64-ios -OReleaseFast -femit-bin=hook.dylib \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  -L"$IOS_SDK/usr/lib" \
  -lc
```

Typical packaging flow afterwards:

1. Copy `hook.dylib` into `MyApp.app/Frameworks/`
2. Use `insert-dylib` to add a load command to the app Mach-O
3. Re-sign the full app bundle
4. Install and run

This repository's iOS support is therefore oriented around **prepatched trap
sites plus inserted dylibs**, matching the workflow described above.

## Android AArch64

Recommended workflow:

- use a sidecar `.so`
- patch the target ELF / native binary with `patch-elf` or equivalent
- let the app or native packaging flow provide the final shared-library link

The Android backend shares the same Linux-family AArch64 signal/context code
path. In local verification, the Android target successfully compiled to object
files against an installed NDK sysroot.

Example compile-to-object smoke commands:

```bash
ANDROID_NDK=$HOME/Library/Android/sdk/ndk/29.0.13113456
ANDROID_SYSROOT=$(find "$ANDROID_NDK/toolchains/llvm/prebuilt" -maxdepth 1 -mindepth 1 -type d | head -n 1)/sysroot

zig build-obj -target aarch64-linux-android -OReleaseFast \
  --sysroot "$ANDROID_SYSROOT" \
  src/root.zig \
  -lc

zig build-obj -target aarch64-linux-android -OReleaseFast \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  --sysroot "$ANDROID_SYSROOT" \
  -lc
```

On the machine used for this implementation, Zig 0.15.2 did not provide a
fully self-contained Android libc link for the final shared library, so the
expected final `.so` link should be driven by the NDK / app build system.

## Verification status

- macOS AArch64: native runtime tests and examples executed locally
- Linux AArch64: core shared library and ELF payload cross-compiled locally
- iOS AArch64: core dylib and Mach-O payload cross-compiled locally
- Android AArch64: core library and payload compiled to object files against a
  local NDK sysroot
