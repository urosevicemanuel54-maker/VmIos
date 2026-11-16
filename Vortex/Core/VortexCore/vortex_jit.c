//
//  vortex_jit.c
//  Vortex
//
//  JIT breakpoint protocol and executable arena.
//

#include "vortex_jit.h"
#include "vortex_host.h"

#include <libkern/OSCacheControl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__aarch64__)
__attribute__((noinline, optnone, naked))
void vortex_jit26_detach(void)
{
    __asm__(
        "mov x16, #0\n"
        "brk #0xf00d\n"
        "ret\n"
    );
}

__attribute__((noinline, optnone, naked))
void *vortex_jit26_prepare_region(void *address, size_t length)
{
    __asm__(
        "mov x16, #1\n"
        "brk #0xf00d\n"
        "ret\n"
    );
}
#else
void vortex_jit26_detach(void)
{
}

void *vortex_jit26_prepare_region(void *address, size_t length)
{
    (void)address;
    (void)length;
    return NULL;
}
#endif

struct vortex_jit_pool {
    uint8_t *base;
    size_t capacity;
    size_t used;
    bool sealed;
};

vortex_jit_pool *vortex_jit_pool_create(size_t capacity)
{
    if (capacity == 0u) {
        return NULL;
    }

    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0) {
        return NULL;
    }
    size_t page_size = (size_t)page;
    size_t rounded = ((capacity + page_size - 1u) / page_size) * page_size;

    void *region = mmap(NULL,
                        rounded,
                        PROT_READ | PROT_WRITE | PROT_EXEC,
                        MAP_PRIVATE | MAP_ANON | MAP_JIT,
                        -1,
                        0);
    if (region == MAP_FAILED) {
        return NULL;
    }

    vortex_jit_pool *pool = (vortex_jit_pool *)calloc(1, sizeof(*pool));
    if (pool == NULL) {
        munmap(region, rounded);
        return NULL;
    }

    pool->base = (uint8_t *)region;
    pool->capacity = rounded;
    pool->used = 0;
    pool->sealed = false;
    return pool;
}

void vortex_jit_pool_destroy(vortex_jit_pool *pool)
{
    if (pool == NULL) {
        return;
    }
    if (pool->base != NULL) {
        munmap(pool->base, pool->capacity);
    }
    free(pool);
}

void *vortex_jit_pool_alloc(vortex_jit_pool *pool, size_t size)
{
    if (pool == NULL || pool->sealed || size == 0u) {
        return NULL;
    }
    size_t aligned = (pool->used + 15u) & ~(size_t)15u;
    if (aligned + size > pool->capacity) {
        return NULL;
    }
    void *pointer = pool->base + aligned;
    pool->used = aligned + size;
    return pointer;
}

bool vortex_jit_pool_seal(vortex_jit_pool *pool)
{
    if (pool == NULL) {
        return false;
    }
    if (pool->sealed) {
        return true;
    }
    sys_icache_invalidate(pool->base, pool->used);
    vortex_host_jit_write_protect(true);
    pool->sealed = true;
    return true;
}

bool vortex_jit_pool_unseal(vortex_jit_pool *pool)
{
    if (pool == NULL) {
        return false;
    }
    vortex_host_jit_write_protect(false);
    pool->sealed = false;
    return true;
}

bool vortex_jit_self_test(bool execute_code, int *out_result)
{
    if (out_result != NULL) {
        *out_result = 0;
    }

    vortex_jit_pool *pool = vortex_jit_pool_create(16384u);
    if (pool == NULL) {
        return false;
    }

    bool succeeded = false;

#if defined(__aarch64__)
    uint32_t *code = (uint32_t *)vortex_jit_pool_alloc(pool, 8u);
    if (code != NULL) {
        code[0] = 0x52800540u; /* mov w0, #42 */
        code[1] = 0xd65f03c0u; /* ret */
        if (vortex_jit_pool_seal(pool)) {
            succeeded = true;
            if (execute_code) {
                int (*function)(void) = (int (*)(void))(void *)code;
                int value = function();
                if (out_result != NULL) {
                    *out_result = value;
                }
                succeeded = (value == 42);
            }
        }
    }
#else
    void *code = vortex_jit_pool_alloc(pool, 16u);
    if (code != NULL && vortex_jit_pool_seal(pool)) {
        memset(code, 0, 16u);
        succeeded = true;
    }
#endif

    vortex_jit_pool_destroy(pool);
    return succeeded;
}
