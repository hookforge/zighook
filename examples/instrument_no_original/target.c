#include <stdio.h>

#if defined(__APPLE__)
#define ASM_GLOBAL(name) ".globl _" #name "\n"
#define ASM_LABEL(name) "_" #name ":\n"
#else
#define ASM_GLOBAL(name) ".globl " #name "\n"
#define ASM_LABEL(name) #name ":\n"
#endif

__asm__(
".text\n"
".p2align 2\n"
ASM_GLOBAL(target_add)
ASM_GLOBAL(target_add_patchpoint)
ASM_LABEL(target_add)
ASM_LABEL(target_add_patchpoint)
"add w0, w0, w1\n"
"ret\n"
);

extern int target_add(int a, int b);

int main(void) {
    printf("result=%d\n", target_add(2, 3));
    return 0;
}
