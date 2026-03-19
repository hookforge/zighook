# Changelog

## v0.2.0

Released: 2026-03-19

Highlights:

- Added strict AArch64 execute-original replay support for common PC-relative instructions, including `adr`, `adrp`, literal `ldr*`, `b`, `bl`, `b.cond`, `cbz/cbnz`, and `tbz/tbnz`.
- Added callback-visible AArch64 FP/SIMD register access, including indexed and named `v0..v31` views plus `fpsr` and `fpcr`.
- Refactored AArch64 replay decoding around packed bitfield layouts and `@bitCast`, so instruction parsers map directly onto the in-memory opcode layout.
- Split platform-specific AArch64 context backends into dedicated backend modules for Darwin and Linux-family systems, covering macOS, iOS, Linux, and Android backend targets.
- Restructured examples into standalone mini-projects with per-example documentation and exact expected outputs.
- Added Linux AArch64 runtime smoke coverage in CI alongside the existing macOS runtime smoke coverage.

## v0.1.0

Initial public release.
