.text
.p2align 2

// Simple demo function used by tests and examples:
//   int add(int a, int b) { return a + b; }
//
// `_demo_add_patchpoint` intentionally points at the `add` instruction itself
// so instruction-level APIs can patch or instrument exactly one instruction.
.globl _demo_add_target
.globl _demo_add_patchpoint
_demo_add_target:
_demo_add_patchpoint:
    add w0, w0, w1
    ret

.p2align 2
// Replacement function used by direct branch / detour examples:
//   int mul(int a, int b) { return a * b; }
.globl _demo_mul_replacement
_demo_mul_replacement:
    mul w0, w0, w1
    ret
