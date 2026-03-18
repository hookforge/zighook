#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

__asm__(
".text\n"
".p2align 2\n"
".globl _target_add\n"
".globl _target_add_patchpoint\n"
"_target_add:\n"
"_target_add_patchpoint:\n"
"add w0, w0, w1\n"
"ret\n"
);

extern int target_add(int a, int b);

typedef void (*unhook_fn_t)(void);

int main(void) {
    unhook_fn_t unhook_fn = (unhook_fn_t)dlsym(RTLD_DEFAULT, "zighook_example_unhook");
    if (unhook_fn == NULL) {
        fprintf(stderr, "missing unhook helper\n");
        return 1;
    }

    printf("hooked=%d\n", target_add(2, 3));
    unhook_fn();
    printf("restored=%d\n", target_add(2, 3));
    return 0;
}
