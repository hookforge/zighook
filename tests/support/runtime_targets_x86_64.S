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

// Replay test for an ordinary unconditional relative jump.
.globl SYM(demo_direct_jump_target)
.globl SYM(demo_direct_jump_patchpoint)
SYM(demo_direct_jump_target):
SYM(demo_direct_jump_patchpoint):
    jmp SYM(demo_direct_jump_impl)

.globl SYM(demo_direct_jump_impl)
SYM(demo_direct_jump_impl):
    movl $7, %eax
    ret

// Replay test for an indirect RIP-relative call through a nearby code pointer
// slot. This exercises the copied-instruction path that rewrites `call r/m64`
// into `jmp r/m64` after synthesizing the original return-address push.
.globl SYM(demo_rip_indirect_call_target)
.globl SYM(demo_rip_indirect_call_patchpoint)
SYM(demo_rip_indirect_call_target):
SYM(demo_rip_indirect_call_patchpoint):
    call *SYM(demo_rip_indirect_call_slot)(%rip)
    ret

.globl SYM(demo_rip_indirect_call_impl)
SYM(demo_rip_indirect_call_impl):
    leal (%rdi,%rsi), %eax
    ret

// Replay test for an indirect RIP-relative jump through a nearby code pointer
// slot.
.globl SYM(demo_rip_indirect_jump_target)
.globl SYM(demo_rip_indirect_jump_patchpoint)
SYM(demo_rip_indirect_jump_target):
SYM(demo_rip_indirect_jump_patchpoint):
    jmp *SYM(demo_rip_indirect_jump_slot)(%rip)

.globl SYM(demo_rip_indirect_jump_impl)
SYM(demo_rip_indirect_jump_impl):
    movl $11, %eax
    ret

// Replay test for a plain RIP-relative data load.
.globl SYM(demo_rip_load_target)
.globl SYM(demo_rip_load_patchpoint)
SYM(demo_rip_load_target):
SYM(demo_rip_load_patchpoint):
    movl SYM(demo_rip_load_value)(%rip), %eax
    ret

// Replay test for a conditional branch. The callback edits ZF in the public
// context before the trapped `jz` is replayed.
.globl SYM(demo_conditional_branch_target)
.globl SYM(demo_conditional_branch_patchpoint)
SYM(demo_conditional_branch_target):
    testl %edi, %edi
SYM(demo_conditional_branch_patchpoint):
    jz SYM(demo_conditional_branch_taken)
    movl $5, %eax
    ret

.globl SYM(demo_conditional_branch_taken)
SYM(demo_conditional_branch_taken):
    movl $42, %eax
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

.data
.p2align 3

SYM(demo_rip_indirect_call_slot):
    .quad SYM(demo_rip_indirect_call_impl)

SYM(demo_rip_indirect_jump_slot):
    .quad SYM(demo_rip_indirect_jump_impl)

.p2align 2
SYM(demo_rip_load_value):
    .long 17
