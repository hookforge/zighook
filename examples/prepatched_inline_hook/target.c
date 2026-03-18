#include <stdio.h>

__asm__(
".text\n"
".p2align 2\n"
".globl _target_prepatched\n"
"_target_prepatched:\n"
".inst 0xD4200000\n"
"ret\n"
);

extern int target_prepatched(void);

int main(void) {
    printf("result=%d\n", target_prepatched());
    return 0;
}
