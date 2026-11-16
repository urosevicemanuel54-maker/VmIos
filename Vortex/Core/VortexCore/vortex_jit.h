//
//  vortex_jit.h
//  Vortex
//
//  The JIT side of the core: the iOS 26 universal breakpoint protocol and a
//  small executable-code arena used to verify that JIT really works.
//

#ifndef VORTEX_JIT_H
#define VORTEX_JIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// iOS 26 universal protocol, exactly as documented by StikJIT.
/// Both calls must only be made while a JIT script is attached and after
/// CS_DEBUGGED is set; a `brk` without the script attached faults.
void vortex_jit26_detach(void);
void *vortex_jit26_prepare_region(void *address, size_t length);

typedef struct vortex_jit_pool vortex_jit_pool;

/// Creates a MAP_JIT arena. Returns NULL when executable JIT memory is not
/// permitted for this process, which is the normal state before activation.
vortex_jit_pool *vortex_jit_pool_create(size_t capacity);

/// Releases the arena. Passing NULL is a no-op.
void vortex_jit_pool_destroy(vortex_jit_pool *pool);

/// Bump-allocates inside the arena, 16-byte aligned. Returns a writable
/// pointer, or NULL when sealed or full.
void *vortex_jit_pool_alloc(vortex_jit_pool *pool, size_t size);

/// Flushes the instruction cache and enables write protection.
bool vortex_jit_pool_seal(vortex_jit_pool *pool);

/// Re-enables writes for the arena.
bool vortex_jit_pool_unseal(vortex_jit_pool *pool);

/// Allocates executable JIT memory and writes `mov w0, #42; ret` into it.
/// When `execute_code` is true the code is called and the result compared with
/// 42. Only pass true on systems where debugger attachment alone enables JIT
/// (documented as iOS 17.4 to 18.x); executing unprepared regions on TXM
/// systems faults.
bool vortex_jit_self_test(bool execute_code, int *out_result);

#ifdef __cplusplus
}
#endif

#endif /* VORTEX_JIT_H */
