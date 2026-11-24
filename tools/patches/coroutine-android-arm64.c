/*
 * Coroutine backend for QEMU on Android arm64 (bionic).
 *
 * Replaces util/coroutine-sigaltstack.c (build-qemu-android.sh copies this file
 * over it). QEMU's stock backends switch stacks with sigsetjmp()/siglongjmp().
 * On recent Android (PAC + shadow call stack enabled devices) bionic's longjmp
 * validates the jmp_buf cookie/SCS state and kills the process with SIGILL when
 * it is used to jump between stacks it did not set up. This backend never calls
 * libc: the stack switch is a few instructions of inline assembly that save and
 * restore the AAPCS64 callee-saved registers. x18 (the platform register that
 * holds the shadow call stack pointer on Android) is deliberately left alone.
 *
 * Based on QEMU's coroutine-ucontext.c (LGPL-2.0-or-later).
 */
#include "qemu/osdep.h"
#include "qemu/coroutine_int.h"
#include "qemu/coroutine-tls.h"

#if !defined(__aarch64__)
#error "coroutine-android-arm64.c only supports aarch64"
#endif

typedef struct {
    Coroutine base;
    void *stack;
    size_t stack_size;
    void *sp;               /* saved stack pointer while switched out */
} CoroutineAsm;

/* Frame layout (bytes): x19..x28 (80), x29, x30 (16), d8..d15 (64) = 160 */
#define FRAME_SIZE 160

QEMU_DEFINE_STATIC_CO_TLS(Coroutine *, current);
QEMU_DEFINE_STATIC_CO_TLS(CoroutineAsm, leader);

/*
 * void coroutine_asm_switch(void **save_sp, void *new_sp, int action)
 * Pushes callee-saved registers, stores sp in *save_sp, loads new_sp, pops the
 * registers found there and returns `action` in x0 to the resumed context.
 */
extern int coroutine_asm_switch(void **save_sp, void *new_sp, int action);
/* Entry stub for a fresh coroutine: x19 holds the CoroutineAsm pointer. */
extern void coroutine_asm_entry(void);

__asm__(
    ".text\n"
    ".p2align 2\n"
    ".hidden coroutine_asm_switch\n"
    ".type coroutine_asm_switch, %function\n"
    "coroutine_asm_switch:\n"
    "    bti c\n"
    "    sub sp, sp, #160\n"
    "    stp x19, x20, [sp, #0]\n"
    "    stp x21, x22, [sp, #16]\n"
    "    stp x23, x24, [sp, #32]\n"
    "    stp x25, x26, [sp, #48]\n"
    "    stp x27, x28, [sp, #64]\n"
    "    stp x29, x30, [sp, #80]\n"
    "    stp d8,  d9,  [sp, #96]\n"
    "    stp d10, d11, [sp, #112]\n"
    "    stp d12, d13, [sp, #128]\n"
    "    stp d14, d15, [sp, #144]\n"
    "    mov x3, sp\n"
    "    str x3, [x0]\n"
    "    mov sp, x1\n"
    "    ldp x19, x20, [sp, #0]\n"
    "    ldp x21, x22, [sp, #16]\n"
    "    ldp x23, x24, [sp, #32]\n"
    "    ldp x25, x26, [sp, #48]\n"
    "    ldp x27, x28, [sp, #64]\n"
    "    ldp x29, x30, [sp, #80]\n"
    "    ldp d8,  d9,  [sp, #96]\n"
    "    ldp d10, d11, [sp, #112]\n"
    "    ldp d12, d13, [sp, #128]\n"
    "    ldp d14, d15, [sp, #144]\n"
    "    add sp, sp, #160\n"
    "    mov w0, w2\n"
    "    ret\n"
    ".size coroutine_asm_switch, .-coroutine_asm_switch\n"
    ".p2align 2\n"
    ".hidden coroutine_asm_entry\n"
    ".type coroutine_asm_entry, %function\n"
    "coroutine_asm_entry:\n"
    "    bti c\n"
    "    mov x0, x19\n"
    "    bl coroutine_asm_main\n"
    "    brk #0\n"
    ".size coroutine_asm_entry, .-coroutine_asm_entry\n"
);

void coroutine_asm_main(CoroutineAsm *self) __attribute__((used, noreturn, visibility("hidden")));

void coroutine_asm_main(CoroutineAsm *self)
{
    Coroutine *co = &self->base;

    while (true) {
        co->entry(co->entry_arg);
        qemu_coroutine_switch(co, co->caller, COROUTINE_TERMINATE);
    }
}

Coroutine *qemu_coroutine_new(void)
{
    CoroutineAsm *co;
    uint64_t *frame;
    uintptr_t top;

    co = g_malloc0(sizeof(*co));
    co->stack_size = COROUTINE_STACK_SIZE;
    co->stack = qemu_alloc_stack(&co->stack_size);

    top = ((uintptr_t)co->stack + co->stack_size) & ~(uintptr_t)15;
    frame = (uint64_t *)(top - FRAME_SIZE);
    memset(frame, 0, FRAME_SIZE);
    frame[0] = (uint64_t)(uintptr_t)co;                  /* x19 */
    frame[11] = (uint64_t)(uintptr_t)coroutine_asm_entry; /* x30 (lr) */
    co->sp = frame;

    return &co->base;
}

void qemu_coroutine_delete(Coroutine *co_)
{
    CoroutineAsm *co = DO_UPCAST(CoroutineAsm, base, co_);

    qemu_free_stack(co->stack, co->stack_size);
    g_free(co);
}

/*
 * noinline: the TLS address of "current" must be recomputed after every
 * switch because a coroutine may resume on a different thread.
 */
CoroutineAction __attribute__((noinline))
qemu_coroutine_switch(Coroutine *from_, Coroutine *to_,
                      CoroutineAction action)
{
    CoroutineAsm *from = DO_UPCAST(CoroutineAsm, base, from_);
    CoroutineAsm *to = DO_UPCAST(CoroutineAsm, base, to_);

    set_current(to_);
    return coroutine_asm_switch(&from->sp, to->sp, action);
}

Coroutine *qemu_coroutine_self(void)
{
    Coroutine *self = get_current();

    if (!self) {
        CoroutineAsm *leaderp = get_ptr_leader();
        self = &leaderp->base;
        set_current(self);
    }
    return self;
}

bool qemu_in_coroutine(void)
{
    Coroutine *self = get_current();

    return self && self->caller;
}
