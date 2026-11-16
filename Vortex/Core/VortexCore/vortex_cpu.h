//
//  vortex_cpu.h
//  Vortex
//
//  ARM64 guest CPU: register file, decode cache, interpreter and debugger
//  surface (step, run, breakpoints, disassembly, measurements).
//
//  Implemented families: data-processing immediate, data-processing register,
//  loads and stores (unsigned offset and unscaled/pre/post index), branches,
//  and the conditional select family.
//
//  Not implemented: SIMD/FP execution, exceptions, system registers, LDP/STP,
//  pair and literal accesses. Those decode as unknown and raise a typed error.
//

#ifndef VORTEX_CPU_H
#define VORTEX_CPU_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VORTEX_CPU_MEMORY_SIZE (4u * 1024u * 1024u)
#define VORTEX_CPU_MAX_BREAKPOINTS 32u

typedef struct vortex_cpu vortex_cpu;

typedef enum vortex_cpu_error_kind {
    VORTEX_CPU_ERROR_NONE = 0,
    VORTEX_CPU_ERROR_UNIMPLEMENTED = 1,
    VORTEX_CPU_ERROR_MEMORY = 2,
    VORTEX_CPU_ERROR_ALIGNMENT = 3
} vortex_cpu_error_kind;

typedef struct vortex_cpu_snapshot {
    uint64_t pc;
    uint64_t sp;
    uint32_t nzcv;
    uint64_t instructions_executed;
    uint64_t decode_hits;
    uint64_t decode_misses;
    uint64_t error_count;
    uint64_t instructions_per_second;
    bool halted;
    bool error_pending;
} vortex_cpu_snapshot;

vortex_cpu *vortex_cpu_create(void);
void vortex_cpu_destroy(vortex_cpu *cpu);

/// Clears registers, PC, counters, the decode cache and any pending error.
/// Guest memory and breakpoints are preserved.
void vortex_cpu_reset(vortex_cpu *cpu);

/// Zeroes guest memory.
void vortex_cpu_clear_memory(vortex_cpu *cpu);

size_t vortex_cpu_memory_size(const vortex_cpu *cpu);
bool vortex_cpu_write_memory(vortex_cpu *cpu, uint64_t address, const void *bytes, size_t size);
bool vortex_cpu_read_memory(const vortex_cpu *cpu, uint64_t address, void *bytes, size_t size);
bool vortex_cpu_read_instruction(const vortex_cpu *cpu, uint64_t address, uint32_t *instruction);

/// Executes one instruction. Returns false when the instruction could not be
/// executed; the CPU then halts and exposes a typed error.
bool vortex_cpu_step(vortex_cpu *cpu);

/// Executes at most `max_instructions`. Stops early on an error, on a taken
/// breakpoint, or when the count is reached. Returns how many were executed.
size_t vortex_cpu_run(vortex_cpu *cpu, size_t max_instructions);

void vortex_cpu_set_pc(vortex_cpu *cpu, uint64_t pc);
void vortex_cpu_set_sp(vortex_cpu *cpu, uint64_t sp);
uint64_t vortex_cpu_read_register(const vortex_cpu *cpu, uint32_t index);
void vortex_cpu_write_register(vortex_cpu *cpu, uint32_t index, uint64_t value);

/// Copies 32 vector registers as 64 words: out[2n] is the low half of Vn,
/// out[2n + 1] the high half.
void vortex_cpu_copy_vector_registers(const vortex_cpu *cpu, uint64_t *out_words);

bool vortex_cpu_add_breakpoint(vortex_cpu *cpu, uint64_t pc);
bool vortex_cpu_remove_breakpoint(vortex_cpu *cpu, uint64_t pc);
void vortex_cpu_clear_breakpoints(vortex_cpu *cpu);
bool vortex_cpu_has_breakpoint(const vortex_cpu *cpu, uint64_t pc);
size_t vortex_cpu_breakpoint_count(const vortex_cpu *cpu);

void vortex_cpu_copy_snapshot(const vortex_cpu *cpu, vortex_cpu_snapshot *out_snapshot);
bool vortex_cpu_copy_last_error(const vortex_cpu *cpu,
                                uint32_t *out_kind,
                                uint64_t *out_pc,
                                uint32_t *out_instruction,
                                char *out_message,
                                size_t message_capacity);
void vortex_cpu_clear_last_error(vortex_cpu *cpu);

/// Disassembles one word. Returns the number of characters written (excluding
/// the terminator). Unknown encodings render as `.inst 0x????????`.
size_t vortex_cpu_disassemble(uint32_t instruction, uint64_t pc, char *buffer, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* VORTEX_CPU_H */
