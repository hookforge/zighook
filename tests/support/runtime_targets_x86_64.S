#ifdef __APPLE__
#define SYM(x) _##x
#else
#define SYM(x) x
#endif

.text
.p2align 4

// Demo add target used by instruction-level replay tests.
.globl SYM(demo_add_target)
.globl SYM(demo_add_patchpoint)
SYM(demo_add_target):
SYM(demo_add_patchpoint):
    leal (%rdi,%rsi), %eax
    ret

// Replay test for ordinary direct calls. The patchpoint is the `call rel32`
// itself so the execute-original trampoline must synthesize the pushed return
// address before transferring control to the final callee.
.globl SYM(demo_direct_call_target)
.globl SYM(demo_direct_call_patchpoint)
SYM(demo_direct_call_target):
SYM(demo_direct_call_patchpoint):
    call SYM(demo_direct_call_impl)
    ret

.globl SYM(demo_direct_call_impl)
SYM(demo_direct_call_impl):
    leal (%rdi,%rsi), %eax
    ret

// Replay test for stack-pointer-based indirect calls. The patchpoint is the
// indirect call through the top-of-stack function pointer slot.
.globl SYM(demo_stack_call_target)
.globl SYM(demo_stack_call_patchpoint)
SYM(demo_stack_call_target):
    subq $24, %rsp
    leaq SYM(demo_stack_call_impl)(%rip), %rax
    movq %rax, (%rsp)
SYM(demo_stack_call_patchpoint):
    call *(%rsp)
    addq $24, %rsp
    ret

.globl SYM(demo_stack_call_impl)
SYM(demo_stack_call_impl):
    leal (%rdi,%rsi), %eax
    ret

// Simple prepatched entry-hook target for x86_64 tests. The first byte is
// already `int3`, so `prepatched.inline_hook(...)` only needs to register
// runtime dispatch state.
.globl SYM(demo_prepatched_target)
SYM(demo_prepatched_target):
    int3
    ret
