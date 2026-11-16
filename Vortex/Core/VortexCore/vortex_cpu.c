//
//  vortex_cpu.c
//  Vortex
//
//  Table-driven ARM64 interpreter with a decoded-instruction cache.
//
//  Decode is split in two: a 16-entry primary table on instruction bits 28:25
//  selects a group, then a group decoder fills a vortex_decoded record. Records
//  are cached by PC and invalidated by a code serial that advances whenever
//  guest memory is written, so self-modifying code cannot run stale decodes.
//

#include "vortex_cpu.h"

#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define VORTEX_DECODE_CACHE_SIZE 1024u

typedef enum vortex_opcode {
    VORTEX_OP_UNKNOWN = 0,
    VORTEX_OP_NOP,
    VORTEX_OP_ADD_IMM,
    VORTEX_OP_SUB_IMM,
    VORTEX_OP_MOVZ,
    VORTEX_OP_MOVN,
    VORTEX_OP_MOVK,
    VORTEX_OP_AND_IMM,
    VORTEX_OP_ORR_IMM,
    VORTEX_OP_EOR_IMM,
    VORTEX_OP_ANDS_IMM,
    VORTEX_OP_ADR,
    VORTEX_OP_ADRP,
    VORTEX_OP_ADD_REG,
    VORTEX_OP_SUB_REG,
    VORTEX_OP_AND_REG,
    VORTEX_OP_ORR_REG,
    VORTEX_OP_EOR_REG,
    VORTEX_OP_ANDS_REG,
    VORTEX_OP_LSLV,
    VORTEX_OP_LSRV,
    VORTEX_OP_ASRV,
    VORTEX_OP_MADD,
    VORTEX_OP_MSUB,
    VORTEX_OP_UDIV,
    VORTEX_OP_SDIV,
    VORTEX_OP_CSEL,
    VORTEX_OP_CSINC,
    VORTEX_OP_CSINV,
    VORTEX_OP_CSNEG,
    VORTEX_OP_CLZ,
    VORTEX_OP_LDST,
    VORTEX_OP_B,
    VORTEX_OP_BL,
    VORTEX_OP_B_COND,
    VORTEX_OP_CBZ,
    VORTEX_OP_CBNZ,
    VORTEX_OP_TBZ,
    VORTEX_OP_TBNZ,
    VORTEX_OP_BR,
    VORTEX_OP_BLR,
    VORTEX_OP_RET
} vortex_opcode;

typedef enum vortex_ldst_kind {
    VORTEX_LDST_STORE = 0,
    VORTEX_LDST_LOAD_ZERO = 1,
    VORTEX_LDST_LOAD_SIGN64 = 2,
    VORTEX_LDST_LOAD_SIGN32 = 3
} vortex_ldst_kind;

typedef struct vortex_decoded {
    uint32_t raw;
    uint16_t op;
    uint8_t rd;
    uint8_t rn;
    uint8_t rm;
    uint8_t ra;
    uint8_t rt;
    uint8_t cond;
    uint8_t shift_type;
    uint8_t shift_amount;
    uint8_t access_size;
    uint8_t ldst_kind;
    bool is64;
    bool sets_flags;
    bool invert;
    bool is_sub;
    bool writeback;
    int64_t immediate;
    int64_t offset;
    int64_t writeback_offset;
    uint64_t target;
} vortex_decoded;

typedef struct vortex_cache_entry {
    uint64_t pc;
    uint32_t serial;
    bool valid;
    vortex_decoded decoded;
} vortex_cache_entry;

struct vortex_cpu {
    uint64_t x[31];
    uint64_t sp;
    uint64_t pc;
    uint32_t nzcv;
    uint64_t v[32][2];

    uint8_t *memory;
    size_t memory_size;

    vortex_cache_entry *cache;
    uint32_t code_serial;

    uint64_t instructions_executed;
    uint64_t decode_hits;
    uint64_t decode_misses;
    uint64_t error_count;
    uint64_t instructions_per_second;

    bool halted;
    bool error_pending;
    uint32_t error_kind;
    uint64_t error_pc;
    uint32_t error_instruction;
    char error_message[160];

    uint64_t breakpoints[VORTEX_CPU_MAX_BREAKPOINTS];
    size_t breakpoint_count;
};

// MARK: - Small helpers

static double vortex_now_precise_seconds(void)
{
    static mach_timebase_info_data_t timebase;
    static bool initialized = false;
    if (!initialized) {
        mach_timebase_info(&timebase);
        initialized = true;
    }
    uint64_t ticks = mach_absolute_time();
    double nanos = (double)ticks * (double)timebase.numer / (double)timebase.denom;
    return nanos / 1e9;
}

static uint64_t vortex_mask(bool is64)
{
    return is64 ? ~0ull : 0xFFFFFFFFull;
}

static uint32_t vortex_width(bool is64)
{
    return is64 ? 64u : 32u;
}

static uint64_t vortex_reg(const vortex_cpu *cpu, uint32_t index)
{
    return index == 31u ? 0ull : cpu->x[index & 31u];
}

static uint64_t vortex_reg_sp(const vortex_cpu *cpu, uint32_t index)
{
    return index == 31u ? cpu->sp : cpu->x[index & 31u];
}

static void vortex_set_reg(vortex_cpu *cpu, uint32_t index, uint64_t value, bool is64)
{
    if (index == 31u) {
        return;
    }
    cpu->x[index & 31u] = value & vortex_mask(is64);
}

static void vortex_set_reg_sp(vortex_cpu *cpu, uint32_t index, uint64_t value, bool is64)
{
    uint64_t masked = value & vortex_mask(is64);
    if (index == 31u) {
        cpu->sp = masked;
    } else {
        cpu->x[index & 31u] = masked;
    }
}

static uint64_t vortex_shift(uint64_t value, uint32_t type, uint32_t amount, bool is64)
{
    uint32_t bits = vortex_width(is64);
    uint64_t masked = value & vortex_mask(is64);
    uint32_t shift = amount % bits;
    if (shift == 0u) {
        return masked;
    }
    switch (type) {
        case 0: // LSL
            return (masked << shift) & vortex_mask(is64);
        case 1: // LSR
            return masked >> shift;
        case 2: // ASR
            if (is64) {
                return (uint64_t)(((int64_t)masked) >> shift);
            }
            return (uint64_t)(uint32_t)(((int32_t)(uint32_t)masked) >> shift);
        case 3: // ROR
            if (is64) {
                return (masked >> shift) | (masked << (bits - shift));
            }
            return (uint64_t)(uint32_t)(((uint32_t)masked >> shift) | ((uint32_t)masked << (bits - shift)));
        default:
            return masked;
    }
}

static void vortex_set_nzcv(vortex_cpu *cpu, bool n, bool z, bool c, bool v)
{
    cpu->nzcv = (n ? 8u : 0u) | (z ? 4u : 0u) | (c ? 2u : 0u) | (v ? 1u : 0u);
}

static void vortex_flags_add(vortex_cpu *cpu, uint64_t a, uint64_t b, uint64_t result, bool is64)
{
    uint64_t mask = vortex_mask(is64);
    uint64_t sign = is64 ? 0x8000000000000000ull : 0x80000000ull;
    uint64_t masked_a = a & mask;
    uint64_t masked_b = b & mask;
    uint64_t masked_result = result & mask;

    bool n = (masked_result & sign) != 0u;
    bool z = masked_result == 0u;
    bool c;
    if (is64) {
        c = (masked_result < masked_a);
    } else {
        c = ((masked_a + masked_b) > 0xFFFFFFFFull);
    }
    bool v = (((masked_a ^ masked_result) & (masked_b ^ masked_result) & sign) != 0u);
    vortex_set_nzcv(cpu, n, z, c, v);
}

static void vortex_flags_sub(vortex_cpu *cpu, uint64_t a, uint64_t b, uint64_t result, bool is64)
{
    uint64_t mask = vortex_mask(is64);
    uint64_t sign = is64 ? 0x8000000000000000ull : 0x80000000ull;
    uint64_t masked_a = a & mask;
    uint64_t masked_b = b & mask;
    uint64_t masked_result = result & mask;

    bool n = (masked_result & sign) != 0u;
    bool z = masked_result == 0u;
    bool c = masked_a >= masked_b;
    bool v = (((masked_a ^ masked_b) & (masked_a ^ masked_result) & sign) != 0u);
    vortex_set_nzcv(cpu, n, z, c, v);
}

static bool vortex_condition_holds(const vortex_cpu *cpu, uint32_t cond)
{
    bool n = (cpu->nzcv & 8u) != 0u;
    bool z = (cpu->nzcv & 4u) != 0u;
    bool c = (cpu->nzcv & 2u) != 0u;
    bool v = (cpu->nzcv & 1u) != 0u;

    switch (cond & 0xFu) {
        case 0x0: return z;
        case 0x1: return !z;
        case 0x2: return c;
        case 0x3: return !c;
        case 0x4: return n;
        case 0x5: return !n;
        case 0x6: return v;
        case 0x7: return !v;
        case 0x8: return c && !z;
        case 0x9: return !c || z;
        case 0xA: return n == v;
        case 0xB: return n != v;
        case 0xC: return !z && (n == v);
        case 0xD: return z || (n != v);
        case 0xE: return true;
        default: return false;
    }
}

static const char *vortex_condition_name(uint32_t cond)
{
    static const char *names[16] = {
        "eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc",
        "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"
    };
    return names[cond & 0xFu];
}

static bool vortex_decode_bitmask(uint32_t n, uint32_t imms, uint32_t immr, bool is64, uint64_t *out)
{
    if (is64 && n == 0u) {
        return false;
    }
    if (!is64 && n != 0u) {
        return false;
    }

    uint32_t combined = (n << 6) | ((~imms) & 0x3Fu);
    if (combined == 0u) {
        return false;
    }

    int length = 31;
    while (length > 0 && ((combined >> length) & 1u) == 0u) {
        length -= 1;
    }
    if (length < 1) {
        return false;
    }
    if (is64 ? (length > 6) : (length > 5)) {
        return false;
    }

    uint32_t size = 1u << length;
    uint32_t levels = size - 1u;
    uint32_t s = imms & levels;
    uint32_t r = immr & levels;
    if (s == levels) {
        return false;
    }

    uint64_t welem = (s + 1u >= 64u) ? ~0ull : ((1ull << (s + 1u)) - 1ull);
    uint64_t mask_size = (size >= 64u) ? ~0ull : ((1ull << size) - 1ull);
    uint64_t element = 0ull;

    if (size >= 64u) {
        element = r == 0u ? welem : ((welem >> r) | (welem << (64u - r)));
    } else {
        uint64_t source = welem & mask_size;
        element = r == 0u ? source : (((source >> r) | (source << (size - r))) & mask_size);
    }

    uint64_t result = 0ull;
    for (uint32_t index = 0; index < 64u / size; index += 1u) {
        result |= element << (index * size);
    }

    *out = is64 ? result : (result & 0xFFFFFFFFull);
    return true;
}

// MARK: - Errors

static bool vortex_fail(vortex_cpu *cpu, uint32_t kind, uint32_t instruction, uint64_t pc, const char *message)
{
    cpu->halted = true;
    cpu->error_pending = true;
    cpu->error_kind = kind;
    cpu->error_instruction = instruction;
    cpu->error_pc = pc;
    cpu->error_count += 1u;
    snprintf(cpu->error_message, sizeof(cpu->error_message), "%s", message ? message : "unspecified error");
    return false;
}

// MARK: - Lifecycle

vortex_cpu *vortex_cpu_create(void)
{
    vortex_cpu *cpu = (vortex_cpu *)calloc(1, sizeof(*cpu));
    if (cpu == NULL) {
        return NULL;
    }
    cpu->memory = (uint8_t *)calloc(1, VORTEX_CPU_MEMORY_SIZE);
    cpu->cache = (vortex_cache_entry *)calloc(VORTEX_DECODE_CACHE_SIZE, sizeof(vortex_cache_entry));
    if (cpu->memory == NULL || cpu->cache == NULL) {
        free(cpu->memory);
        free(cpu->cache);
        free(cpu);
        return NULL;
    }
    cpu->memory_size = VORTEX_CPU_MEMORY_SIZE;
    vortex_cpu_reset(cpu);
    return cpu;
}

void vortex_cpu_destroy(vortex_cpu *cpu)
{
    if (cpu == NULL) {
        return;
    }
    free(cpu->memory);
    free(cpu->cache);
    free(cpu);
}

void vortex_cpu_reset(vortex_cpu *cpu)
{
    if (cpu == NULL) {
        return;
    }
    memset(cpu->x, 0, sizeof(cpu->x));
    memset(cpu->v, 0, sizeof(cpu->v));
    cpu->sp = 0;
    cpu->pc = 0;
    cpu->nzcv = 0;
    cpu->instructions_executed = 0;
    cpu->decode_hits = 0;
    cpu->decode_misses = 0;
    cpu->error_count = 0;
    cpu->instructions_per_second = 0;
    cpu->halted = false;
    cpu->error_pending = false;
    cpu->error_kind = VORTEX_CPU_ERROR_NONE;
    cpu->error_pc = 0;
    cpu->error_instruction = 0;
    cpu->error_message[0] = '\0';
    cpu->code_serial = 0;
    if (cpu->cache != NULL) {
        memset(cpu->cache, 0, sizeof(vortex_cache_entry) * VORTEX_DECODE_CACHE_SIZE);
    }
}

void vortex_cpu_clear_memory(vortex_cpu *cpu)
{
    if (cpu == NULL || cpu->memory == NULL) {
        return;
    }
    memset(cpu->memory, 0, cpu->memory_size);
    cpu->code_serial += 1u;
}

size_t vortex_cpu_memory_size(const vortex_cpu *cpu)
{
    return cpu == NULL ? 0u : cpu->memory_size;
}

bool vortex_cpu_write_memory(vortex_cpu *cpu, uint64_t address, const void *bytes, size_t size)
{
    if (cpu == NULL || bytes == NULL) {
        return false;
    }
    if (size > cpu->memory_size || address > (uint64_t)cpu->memory_size - size) {
        return false;
    }
    memcpy(cpu->memory + (size_t)address, bytes, size);
    cpu->code_serial += 1u;
    return true;
}

bool vortex_cpu_read_memory(const vortex_cpu *cpu, uint64_t address, void *bytes, size_t size)
{
    if (cpu == NULL || bytes == NULL) {
        return false;
    }
    if (size > cpu->memory_size || address > (uint64_t)cpu->memory_size - size) {
        return false;
    }
    memcpy(bytes, cpu->memory + (size_t)address, size);
    return true;
}

bool vortex_cpu_read_instruction(const vortex_cpu *cpu, uint64_t address, uint32_t *instruction)
{
    return vortex_cpu_read_memory(cpu, address, instruction, sizeof(uint32_t));
}

void vortex_cpu_set_pc(vortex_cpu *cpu, uint64_t pc)
{
    if (cpu != NULL) {
        cpu->pc = pc & ~3ull;
    }
}

void vortex_cpu_set_sp(vortex_cpu *cpu, uint64_t sp)
{
    if (cpu != NULL) {
        cpu->sp = sp;
    }
}

uint64_t vortex_cpu_read_register(const vortex_cpu *cpu, uint32_t index)
{
    if (cpu == NULL) {
        return 0;
    }
    if (index >= 31u) {
        return cpu->sp;
    }
    return cpu->x[index];
}

void vortex_cpu_write_register(vortex_cpu *cpu, uint32_t index, uint64_t value)
{
    if (cpu == NULL) {
        return;
    }
    if (index >= 31u) {
        cpu->sp = value;
        return;
    }
    cpu->x[index] = value;
}

void vortex_cpu_copy_vector_registers(const vortex_cpu *cpu, uint64_t *out_words)
{
    if (cpu == NULL || out_words == NULL) {
        return;
    }
    for (uint32_t index = 0; index < 32u; index += 1u) {
        out_words[index * 2u] = cpu->v[index][0];
        out_words[index * 2u + 1u] = cpu->v[index][1];
    }
}

// MARK: - Breakpoints

bool vortex_cpu_has_breakpoint(const vortex_cpu *cpu, uint64_t pc)
{
    if (cpu == NULL) {
        return false;
    }
    for (size_t index = 0; index < cpu->breakpoint_count; index += 1u) {
        if (cpu->breakpoints[index] == pc) {
            return true;
        }
    }
    return false;
}

bool vortex_cpu_add_breakpoint(vortex_cpu *cpu, uint64_t pc)
{
    if (cpu == NULL || cpu->breakpoint_count >= VORTEX_CPU_MAX_BREAKPOINTS) {
        return false;
    }
    if (vortex_cpu_has_breakpoint(cpu, pc)) {
        return true;
    }
    cpu->breakpoints[cpu->breakpoint_count] = pc;
    cpu->breakpoint_count += 1u;
    return true;
}

bool vortex_cpu_remove_breakpoint(vortex_cpu *cpu, uint64_t pc)
{
    if (cpu == NULL) {
        return false;
    }
    for (size_t index = 0; index < cpu->breakpoint_count; index += 1u) {
        if (cpu->breakpoints[index] == pc) {
            for (size_t move = index; move + 1u < cpu->breakpoint_count; move += 1u) {
                cpu->breakpoints[move] = cpu->breakpoints[move + 1u];
            }
            cpu->breakpoint_count -= 1u;
            return true;
        }
    }
    return false;
}

void vortex_cpu_clear_breakpoints(vortex_cpu *cpu)
{
    if (cpu != NULL) {
        cpu->breakpoint_count = 0;
    }
}

size_t vortex_cpu_breakpoint_count(const vortex_cpu *cpu)
{
    return cpu == NULL ? 0u : cpu->breakpoint_count;
}

// MARK: - Snapshot

void vortex_cpu_copy_snapshot(const vortex_cpu *cpu, vortex_cpu_snapshot *out_snapshot)
{
    if (out_snapshot == NULL) {
        return;
    }
    if (cpu == NULL) {
        memset(out_snapshot, 0, sizeof(*out_snapshot));
        return;
    }
    out_snapshot->pc = cpu->pc;
    out_snapshot->sp = cpu->sp;
    out_snapshot->nzcv = cpu->nzcv;
    out_snapshot->instructions_executed = cpu->instructions_executed;
    out_snapshot->decode_hits = cpu->decode_hits;
    out_snapshot->decode_misses = cpu->decode_misses;
    out_snapshot->error_count = cpu->error_count;
    out_snapshot->instructions_per_second = cpu->instructions_per_second;
    out_snapshot->halted = cpu->halted;
    out_snapshot->error_pending = cpu->error_pending;
}

bool vortex_cpu_copy_last_error(const vortex_cpu *cpu,
                                uint32_t *out_kind,
                                uint64_t *out_pc,
                                uint32_t *out_instruction,
                                char *out_message,
                                size_t message_capacity)
{
    if (cpu == NULL || !cpu->error_pending) {
        return false;
    }
    if (out_kind != NULL) {
        *out_kind = cpu->error_kind;
    }
    if (out_pc != NULL) {
        *out_pc = cpu->error_pc;
    }
    if (out_instruction != NULL) {
        *out_instruction = cpu->error_instruction;
    }
    if (out_message != NULL && message_capacity > 0u) {
        snprintf(out_message, message_capacity, "%s", cpu->error_message);
    }
    return true;
}

void vortex_cpu_clear_last_error(vortex_cpu *cpu)
{
    if (cpu == NULL) {
        return;
    }
    cpu->error_pending = false;
    cpu->error_kind = VORTEX_CPU_ERROR_NONE;
    cpu->error_message[0] = '\0';
    cpu->halted = false;
}

// MARK: - Decode

static const uint8_t vortex_primary_table[16] = {
    /* 0 */ 0, /* 1 */ 0, /* 2 */ 0, /* 3 */ 0,
    /* 4 */ 3, /* 5 */ 2, /* 6 */ 3, /* 7 */ 0,
    /* 8 */ 1, /* 9 */ 1, /* a */ 4, /* b */ 4,
    /* c */ 3, /* d */ 2, /* e */ 3, /* f */ 0
};

// Groups: 0 unknown, 1 data-processing immediate, 2 data-processing register,
// 3 loads and stores, 4 branch/system.

static bool vortex_decode_dp_immediate(uint32_t insn, vortex_decoded *d)
{
    if ((insn & 0x1F000000u) == 0x10000000u) {
        // ADR / ADRP
        bool page = ((insn >> 31) & 1u) != 0u;
        uint32_t immlo = (insn >> 29) & 0x3u;
        uint32_t immhi = (insn >> 5) & 0x7FFFFu;
        int64_t immediate = (int64_t)((immhi << 2) | immlo);
        if (immhi & 0x40000u) {
            immediate |= ~((int64_t)0x1FFFFF);
        }
        d->op = page ? VORTEX_OP_ADRP : VORTEX_OP_ADR;
        d->rd = (uint8_t)(insn & 0x1Fu);
        d->immediate = page ? (immediate << 12) : immediate;
        d->is64 = true;
        return true;
    }

    if ((insn & 0x1F800000u) == 0x11000000u) {
        bool subtract = ((insn >> 30) & 1u) != 0u;
        d->op = subtract ? VORTEX_OP_SUB_IMM : VORTEX_OP_ADD_IMM;
        d->is64 = ((insn >> 31) & 1u) != 0u;
        d->sets_flags = ((insn >> 29) & 1u) != 0u;
        uint32_t shift = (insn >> 22) & 1u;
        uint64_t immediate = (insn >> 10) & 0xFFFu;
        d->immediate = (int64_t)(shift != 0u ? (immediate << 12) : immediate);
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        d->rd = (uint8_t)(insn & 0x1Fu);
        return true;
    }

    if ((insn & 0x1F800000u) == 0x12000000u) {
        uint32_t opc = (insn >> 29) & 0x3u;
        bool is64 = ((insn >> 31) & 1u) != 0u;
        uint32_t n = (insn >> 22) & 1u;
        uint32_t immr = (insn >> 16) & 0x3Fu;
        uint32_t imms = (insn >> 10) & 0x3Fu;
        uint64_t bitmask = 0;
        if (!vortex_decode_bitmask(n, imms, immr, is64, &bitmask)) {
            return false;
        }
        switch (opc) {
            case 0: d->op = VORTEX_OP_AND_IMM; break;
            case 1: d->op = VORTEX_OP_ORR_IMM; break;
            case 2: d->op = VORTEX_OP_EOR_IMM; break;
            default: d->op = VORTEX_OP_ANDS_IMM; break;
        }
        d->is64 = is64;
        d->sets_flags = (opc == 3u);
        d->immediate = (int64_t)bitmask;
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        d->rd = (uint8_t)(insn & 0x1Fu);
        return true;
    }

    if ((insn & 0x1F800000u) == 0x12800000u) {
        uint32_t opc = (insn >> 29) & 0x3u;
        bool is64 = ((insn >> 31) & 1u) != 0u;
        uint32_t shift = ((insn >> 21) & 0x3u) * 16u;
        uint64_t immediate = (insn >> 5) & 0xFFFFu;
        if (opc == 0) {
            d->op = VORTEX_OP_MOVN;
        } else if (opc == 2) {
            d->op = VORTEX_OP_MOVZ;
        } else if (opc == 3) {
            d->op = VORTEX_OP_MOVK;
        } else {
            return false;
        }
        d->is64 = is64;
        d->shift_amount = (uint8_t)shift;
        d->immediate = (int64_t)(immediate << shift);
        d->rd = (uint8_t)(insn & 0x1Fu);
        return true;
    }

    return false;
}

static bool vortex_decode_dp_register(uint32_t insn, vortex_decoded *d)
{
    bool is64 = ((insn >> 31) & 1u) != 0u;

    // Data-processing (1 source) — CLZ only.
    if ((insn & 0xFFFFFC00u) == 0xDAC01000u || (insn & 0xFFFFFC00u) == 0x5AC01000u) {
        d->op = VORTEX_OP_CLZ;
        d->is64 = is64;
        d->rd = (uint8_t)(insn & 0x1Fu);
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        return true;
    }

    // Data-processing (2 source) — shifts and division.
    if ((insn & 0x1FE00000u) == 0x1AC00000u) {
        uint32_t opcode = (insn >> 10) & 0x3Fu;
        switch (opcode) {
            case 0x02: d->op = VORTEX_OP_UDIV; break;
            case 0x03: d->op = VORTEX_OP_SDIV; break;
            case 0x08: d->op = VORTEX_OP_LSLV; break;
            case 0x09: d->op = VORTEX_OP_LSRV; break;
            case 0x0A: d->op = VORTEX_OP_ASRV; break;
            default: return false;
        }
        d->is64 = is64;
        d->rd = (uint8_t)(insn & 0x1Fu);
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        d->rm = (uint8_t)((insn >> 16) & 0x1Fu);
        return true;
    }

    // Conditional select family.
    if ((insn & 0x1FE00000u) == 0x1A800000u) {
        uint32_t op2 = (insn >> 10) & 0x3u;
        switch (op2) {
            case 0: d->op = VORTEX_OP_CSEL; break;
            case 1: d->op = VORTEX_OP_CSINC; break;
            case 2: d->op = VORTEX_OP_CSINV; break;
            default: d->op = VORTEX_OP_CSNEG; break;
        }
        d->is64 = is64;
        d->rd = (uint8_t)(insn & 0x1Fu);
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        d->rm = (uint8_t)((insn >> 16) & 0x1Fu);
        d->cond = (uint8_t)((insn >> 12) & 0xFu);
        return true;
    }

    // Data-processing (3 source) — MADD/MSUB.
    if ((insn & 0x1FE08000u) == 0x1B000000u || (insn & 0x1FE08000u) == 0x1B008000u) {
        d->op = ((insn >> 15) & 1u) != 0u ? VORTEX_OP_MSUB : VORTEX_OP_MADD;
        d->is64 = is64;
        d->rd = (uint8_t)(insn & 0x1Fu);
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        d->rm = (uint8_t)((insn >> 16) & 0x1Fu);
        d->ra = (uint8_t)((insn >> 10) & 0x1Fu);
        return true;
    }

    // Add/subtract (shifted register).
    if ((insn & 0x1F000000u) == 0x0B000000u) {
        d->op = ((insn >> 30) & 1u) != 0u ? VORTEX_OP_SUB_REG : VORTEX_OP_ADD_REG;
        d->is64 = is64;
        d->sets_flags = ((insn >> 29) & 1u) != 0u;
        d->shift_type = (uint8_t)((insn >> 22) & 0x3u);
        d->shift_amount = (uint8_t)((insn >> 10) & 0x3Fu);
        d->rd = (uint8_t)(insn & 0x1Fu);
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        d->rm = (uint8_t)((insn >> 16) & 0x1Fu);
        return true;
    }

    // Logical (shifted register), including the inverted forms.
    if ((insn & 0x1F000000u) == 0x0A000000u) {
        bool invert = ((insn >> 21) & 1u) != 0u;
        uint32_t opc = (insn >> 29) & 0x3u;
        switch (opc) {
            case 0: d->op = VORTEX_OP_AND_REG; break;
            case 1: d->op = VORTEX_OP_ORR_REG; break;
            case 2: d->op = VORTEX_OP_EOR_REG; break;
            default: d->op = VORTEX_OP_ANDS_REG; break;
        }
        d->invert = invert;
        d->is64 = is64;
        d->sets_flags = (opc == 3u);
        d->shift_type = (uint8_t)((insn >> 22) & 0x3u);
        d->shift_amount = (uint8_t)((insn >> 10) & 0x3Fu);
        d->rd = (uint8_t)(insn & 0x1Fu);
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        d->rm = (uint8_t)((insn >> 16) & 0x1Fu);
        return true;
    }

    return false;
}

static bool vortex_decode_ldst(uint32_t insn, vortex_decoded *d)
{
    if (((insn >> 26) & 1u) != 0u) {
        // SIMD/FP accesses are out of scope for this milestone.
        return false;
    }

    bool unsignedOffset = (insn & 0x3B000000u) == 0x39000000u;
    bool unscaled = (insn & 0x3B000000u) == 0x38000000u;
    if (!unsignedOffset && !unscaled) {
        return false;
    }

    uint32_t size = (insn >> 30) & 0x3u;
    uint32_t opc = (insn >> 22) & 0x3u;

    if (opc == 0u) {
        d->ldst_kind = VORTEX_LDST_STORE;
    } else if (opc == 1u) {
        d->ldst_kind = VORTEX_LDST_LOAD_ZERO;
    } else if (opc == 2u) {
        d->ldst_kind = VORTEX_LDST_LOAD_SIGN64;
    } else {
        d->ldst_kind = VORTEX_LDST_LOAD_SIGN32;
    }

    if (d->ldst_kind == VORTEX_LDST_STORE && size == 3u) {
        d->access_size = 8u;
    } else {
        static const uint8_t sizes[4] = { 1u, 2u, 4u, 8u };
        d->access_size = sizes[size & 0x3u];
    }

    d->op = VORTEX_OP_LDST;
    d->is64 = (d->access_size == 8u);
    d->rt = (uint8_t)(insn & 0x1Fu);
    d->rn = (uint8_t)((insn >> 5) & 0x1Fu);

    if (unsignedOffset) {
        uint64_t immediate = (insn >> 10) & 0xFFFu;
        d->offset = (int64_t)(immediate * (uint64_t)d->access_size);
        d->writeback = false;
        return true;
    }

    uint32_t mode = (insn >> 10) & 0x3u;
    int64_t immediate = (int64_t)((insn >> 12) & 0x1FFu);
    if ((immediate & 0x100) != 0) {
        immediate -= 0x200;
    }

    switch (mode) {
        case 0: // unscaled
            d->offset = immediate;
            d->writeback = false;
            break;
        case 1: // post-index
            d->offset = 0;
            d->writeback = true;
            d->writeback_offset = immediate;
            break;
        case 3: // pre-index
            d->offset = immediate;
            d->writeback = true;
            d->writeback_offset = immediate;
            break;
        default:
            return false;
    }
    return true;
}

static bool vortex_decode_branch(uint32_t insn, vortex_decoded *d, uint64_t pc)
{
    if (insn == 0xD503201Fu) {
        d->op = VORTEX_OP_NOP;
        return true;
    }

    if ((insn & 0x7C000000u) == 0x14000000u) {
        bool link = ((insn >> 31) & 1u) != 0u;
        int64_t immediate = (int64_t)(insn & 0x3FFFFFFu);
        if ((insn & 0x02000000u) != 0u) {
            immediate |= ~((int64_t)0x3FFFFFF);
        }
        immediate <<= 2;
        d->op = link ? VORTEX_OP_BL : VORTEX_OP_B;
        d->target = (uint64_t)((int64_t)pc + immediate);
        return true;
    }

    if ((insn & 0xFF000010u) == 0x54000000u) {
        int64_t immediate = (int64_t)((insn >> 5) & 0x7FFFFu);
        if ((immediate & 0x40000) != 0) {
            immediate |= ~((int64_t)0x7FFFF);
        }
        d->op = VORTEX_OP_B_COND;
        d->cond = (uint8_t)(insn & 0xFu);
        d->target = (uint64_t)((int64_t)pc + (immediate << 2));
        return true;
    }

    if ((insn & 0x7E000000u) == 0x34000000u) {
        bool nonzero = ((insn >> 24) & 1u) != 0u;
        int64_t immediate = (int64_t)((insn >> 5) & 0x7FFFFu);
        if ((immediate & 0x40000) != 0) {
            immediate |= ~((int64_t)0x7FFFF);
        }
        d->op = nonzero ? VORTEX_OP_CBNZ : VORTEX_OP_CBZ;
        d->is64 = ((insn >> 31) & 1u) != 0u;
        d->rt = (uint8_t)(insn & 0x1Fu);
        d->target = (uint64_t)((int64_t)pc + (immediate << 2));
        return true;
    }

    if ((insn & 0x7E000000u) == 0x36000000u) {
        bool nonzero = ((insn >> 24) & 1u) != 0u;
        int64_t immediate = (int64_t)((insn >> 5) & 0x3FFFu);
        if ((immediate & 0x2000) != 0) {
            immediate |= ~((int64_t)0x3FFF);
        }
        uint32_t bit = ((insn >> 26) & 0x20u) | ((insn >> 19) & 0x1Fu);
        d->op = nonzero ? VORTEX_OP_TBNZ : VORTEX_OP_TBZ;
        d->rt = (uint8_t)(insn & 0x1Fu);
        d->shift_amount = (uint8_t)bit;
        d->target = (uint64_t)((int64_t)pc + (immediate << 2));
        return true;
    }

    if ((insn & 0xFFFFFC1Fu) == 0xD61F0000u) {
        d->op = VORTEX_OP_BR;
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        return true;
    }
    if ((insn & 0xFFFFFC1Fu) == 0xD63F0000u) {
        d->op = VORTEX_OP_BLR;
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        return true;
    }
    if ((insn & 0xFFFFFC1Fu) == 0xD65F0000u) {
        d->op = VORTEX_OP_RET;
        d->rn = (uint8_t)((insn >> 5) & 0x1Fu);
        return true;
    }

    return false;
}

static bool vortex_decode(vortex_cpu *cpu, uint32_t insn, uint64_t pc, vortex_decoded *d)
{
    (void)cpu;
    memset(d, 0, sizeof(*d));
    d->raw = insn;

    uint32_t op1 = (insn >> 25) & 0xFu;
    switch (vortex_primary_table[op1]) {
        case 1: return vortex_decode_dp_immediate(insn, d);
        case 2: return vortex_decode_dp_register(insn, d);
        case 3: return vortex_decode_ldst(insn, d);
        case 4: return vortex_decode_branch(insn, d, pc);
        default: return false;
    }
}

static bool vortex_fetch_decoded(vortex_cpu *cpu, uint64_t pc, vortex_decoded *out)
{
    uint32_t index = (uint32_t)((pc >> 2) & (VORTEX_DECODE_CACHE_SIZE - 1u));
    vortex_cache_entry *entry = &cpu->cache[index];

    if (entry->valid && entry->pc == pc && entry->serial == cpu->code_serial) {
        cpu->decode_hits += 1u;
        *out = entry->decoded;
        return true;
    }

    uint32_t instruction = 0;
    if (!vortex_cpu_read_instruction(cpu, pc, &instruction)) {
        return vortex_fail(cpu, VORTEX_CPU_ERROR_MEMORY, 0, pc, "instruction fetch outside guest memory");
    }

    vortex_decoded decoded;
    if (!vortex_decode(cpu, instruction, pc, &decoded)) {
        char message[160];
        snprintf(message, sizeof(message), "unimplemented encoding 0x%08x", instruction);
        return vortex_fail(cpu, VORTEX_CPU_ERROR_UNIMPLEMENTED, instruction, pc, message);
    }

    cpu->decode_misses += 1u;
    entry->pc = pc;
    entry->serial = cpu->code_serial;
    entry->valid = true;
    entry->decoded = decoded;
    *out = decoded;
    return true;
}

// MARK: - Execute

static bool vortex_mem_read(vortex_cpu *cpu, uint64_t address, uint32_t size, uint64_t *out_value)
{
    uint64_t value = 0;
    if (!vortex_cpu_read_memory(cpu, address, &value, size)) {
        return vortex_fail(cpu, VORTEX_CPU_ERROR_MEMORY, 0, cpu->pc, "load outside guest memory");
    }
    *out_value = value;
    return true;
}

static bool vortex_mem_write(vortex_cpu *cpu, uint64_t address, uint32_t size, uint64_t value)
{
    if (!vortex_cpu_write_memory(cpu, address, &value, size)) {
        return vortex_fail(cpu, VORTEX_CPU_ERROR_MEMORY, 0, cpu->pc, "store outside guest memory");
    }
    return true;
}

static bool vortex_execute(vortex_cpu *cpu, const vortex_decoded *d)
{
    uint64_t next_pc = cpu->pc + 4u;

    switch (d->op) {
        case VORTEX_OP_NOP:
            break;

        case VORTEX_OP_ADD_IMM:
        case VORTEX_OP_SUB_IMM: {
            uint64_t a = vortex_reg_sp(cpu, d->rn);
            uint64_t b = (uint64_t)d->immediate;
            uint64_t result;
            if (d->op == VORTEX_OP_SUB_IMM) {
                result = (a - b) & vortex_mask(d->is64);
                if (d->sets_flags) {
                    vortex_flags_sub(cpu, a, b, result, d->is64);
                }
            } else {
                result = (a + b) & vortex_mask(d->is64);
                if (d->sets_flags) {
                    vortex_flags_add(cpu, a, b, result, d->is64);
                }
            }
            if (d->sets_flags) {
                vortex_set_reg(cpu, d->rd, result, d->is64);
            } else {
                vortex_set_reg_sp(cpu, d->rd, result, d->is64);
            }
            break;
        }

        case VORTEX_OP_MOVZ:
            vortex_set_reg(cpu, d->rd, (uint64_t)d->immediate, d->is64);
            break;

        case VORTEX_OP_MOVN:
            vortex_set_reg(cpu, d->rd, ~(uint64_t)d->immediate, d->is64);
            break;

        case VORTEX_OP_MOVK: {
            uint64_t current = vortex_reg(cpu, d->rd);
            uint64_t mask = 0xFFFFull << d->shift_amount;
            uint64_t value = (current & ~mask) | ((uint64_t)d->immediate & mask);
            vortex_set_reg(cpu, d->rd, value, d->is64);
            break;
        }

        case VORTEX_OP_AND_IMM:
        case VORTEX_OP_ORR_IMM:
        case VORTEX_OP_EOR_IMM:
        case VORTEX_OP_ANDS_IMM: {
            uint64_t a = vortex_reg(cpu, d->rn);
            uint64_t b = (uint64_t)d->immediate;
            uint64_t result;
            switch (d->op) {
                case VORTEX_OP_AND_IMM: result = a & b; break;
                case VORTEX_OP_ORR_IMM: result = a | b; break;
                case VORTEX_OP_EOR_IMM: result = a ^ b; break;
                default: result = a & b; break;
            }
            result &= vortex_mask(d->is64);
            if (d->op == VORTEX_OP_ANDS_IMM) {
                vortex_set_nzcv(cpu, (result & (d->is64 ? 0x8000000000000000ull : 0x80000000ull)) != 0u,
                                result == 0u, false, false);
            }
            vortex_set_reg(cpu, d->rd, result, d->is64);
            break;
        }

        case VORTEX_OP_ADR:
            vortex_set_reg(cpu, d->rd, (uint64_t)((int64_t)cpu->pc + d->immediate), true);
            break;

        case VORTEX_OP_ADRP: {
            uint64_t page = cpu->pc & ~0xFFFull;
            vortex_set_reg(cpu, d->rd, page + (uint64_t)d->immediate, true);
            break;
        }

        case VORTEX_OP_ADD_REG:
        case VORTEX_OP_SUB_REG: {
            uint64_t a = vortex_reg(cpu, d->rn);
            uint64_t b = vortex_shift(vortex_reg(cpu, d->rm), d->shift_type, d->shift_amount, d->is64);
            uint64_t result;
            if (d->op == VORTEX_OP_SUB_REG) {
                result = (a - b) & vortex_mask(d->is64);
                if (d->sets_flags) {
                    vortex_flags_sub(cpu, a, b, result, d->is64);
                }
            } else {
                result = (a + b) & vortex_mask(d->is64);
                if (d->sets_flags) {
                    vortex_flags_add(cpu, a, b, result, d->is64);
                }
            }
            if (d->sets_flags) {
                vortex_set_reg(cpu, d->rd, result, d->is64);
            } else {
                vortex_set_reg_sp(cpu, d->rd, result, d->is64);
            }
            break;
        }

        case VORTEX_OP_AND_REG:
        case VORTEX_OP_ORR_REG:
        case VORTEX_OP_EOR_REG:
        case VORTEX_OP_ANDS_REG: {
            uint64_t a = vortex_reg(cpu, d->rn);
            uint64_t b = vortex_shift(vortex_reg(cpu, d->rm), d->shift_type, d->shift_amount, d->is64);
            if (d->invert) {
                b = ~b & vortex_mask(d->is64);
            }
            uint64_t result;
            switch (d->op) {
                case VORTEX_OP_AND_REG: result = a & b; break;
                case VORTEX_OP_ORR_REG: result = a | b; break;
                case VORTEX_OP_EOR_REG: result = a ^ b; break;
                default: result = a & b; break;
            }
            result &= vortex_mask(d->is64);
            if (d->sets_flags) {
                vortex_set_nzcv(cpu, (result & (d->is64 ? 0x8000000000000000ull : 0x80000000ull)) != 0u,
                                result == 0u, false, false);
            }
            vortex_set_reg(cpu, d->rd, result, d->is64);
            break;
        }

        case VORTEX_OP_LSLV:
        case VORTEX_OP_LSRV:
        case VORTEX_OP_ASRV: {
            uint64_t a = vortex_reg(cpu, d->rn);
            uint64_t amount = vortex_reg(cpu, d->rm) % vortex_width(d->is64);
            uint32_t type = d->op == VORTEX_OP_LSLV ? 0u : (d->op == VORTEX_OP_LSRV ? 1u : 2u);
            vortex_set_reg(cpu, d->rd, vortex_shift(a, type, (uint32_t)amount, d->is64), d->is64);
            break;
        }

        case VORTEX_OP_MADD:
        case VORTEX_OP_MSUB: {
            uint64_t a = vortex_reg(cpu, d->rn);
            uint64_t b = vortex_reg(cpu, d->rm);
            uint64_t addend = vortex_reg(cpu, d->ra);
            uint64_t product = (a * b) & vortex_mask(d->is64);
            uint64_t result = d->op == VORTEX_OP_MADD ? (product + addend) : (addend - product);
            vortex_set_reg(cpu, d->rd, result, d->is64);
            break;
        }

        case VORTEX_OP_UDIV: {
            uint64_t divisor = vortex_reg(cpu, d->rm);
            uint64_t dividend = vortex_reg(cpu, d->rn);
            uint64_t result = divisor == 0u ? 0u : (d->is64 ? (dividend / divisor)
                                                           : (uint64_t)((uint32_t)dividend / (uint32_t)divisor));
            vortex_set_reg(cpu, d->rd, result, d->is64);
            break;
        }

        case VORTEX_OP_SDIV: {
            if (!d->is64) {
                int32_t dividend = (int32_t)(uint32_t)vortex_reg(cpu, d->rn);
                int32_t divisor = (int32_t)(uint32_t)vortex_reg(cpu, d->rm);
                int32_t quotient = 0;
                if (divisor != 0) {
                    if (divisor == -1 && dividend == INT32_MIN) {
                        quotient = INT32_MIN;
                    } else {
                        quotient = dividend / divisor;
                    }
                }
                vortex_set_reg(cpu, d->rd, (uint64_t)(uint32_t)quotient, false);
                break;
            }

            int64_t dividend = (int64_t)vortex_reg(cpu, d->rn);
            int64_t divisor = (int64_t)vortex_reg(cpu, d->rm);
            int64_t quotient = 0;
            if (divisor != 0) {
                if (divisor == -1 && dividend == INT64_MIN) {
                    quotient = dividend;
                } else {
                    quotient = dividend / divisor;
                }
            }
            vortex_set_reg(cpu, d->rd, (uint64_t)quotient, true);
            break;
        }

        case VORTEX_OP_CSEL:
        case VORTEX_OP_CSINC:
        case VORTEX_OP_CSINV:
        case VORTEX_OP_CSNEG: {
            uint64_t a = vortex_reg(cpu, d->rn);
            uint64_t b = vortex_reg(cpu, d->rm);
            uint64_t result;
            if (vortex_condition_holds(cpu, d->cond)) {
                result = a;
            } else {
                switch (d->op) {
                    case VORTEX_OP_CSINC: result = b + 1u; break;
                    case VORTEX_OP_CSINV: result = ~b; break;
                    case VORTEX_OP_CSNEG: result = (uint64_t)(-(int64_t)b); break;
                    default: result = b; break;
                }
            }
            vortex_set_reg(cpu, d->rd, result, d->is64);
            break;
        }

        case VORTEX_OP_CLZ: {
            uint64_t value = vortex_reg(cpu, d->rn);
            uint32_t count = 0;
            if (d->is64) {
                if (value == 0u) {
                    count = 64u;
                } else {
                    while ((value & 0x8000000000000000ull) == 0u) {
                        value <<= 1;
                        count += 1u;
                    }
                }
            } else {
                uint32_t narrow = (uint32_t)value;
                if (narrow == 0u) {
                    count = 32u;
                } else {
                    while ((narrow & 0x80000000u) == 0u) {
                        narrow <<= 1;
                        count += 1u;
                    }
                }
            }
            vortex_set_reg(cpu, d->rd, count, d->is64);
            break;
        }

        case VORTEX_OP_LDST: {
            uint64_t base = vortex_reg_sp(cpu, d->rn);
            uint64_t address = (uint64_t)((int64_t)base + d->offset);

            if (d->ldst_kind == VORTEX_LDST_STORE) {
                uint64_t value = vortex_reg(cpu, d->rt);
                if (!vortex_mem_write(cpu, address, d->access_size, value)) {
                    return false;
                }
            } else {
                uint64_t raw = 0;
                if (!vortex_mem_read(cpu, address, d->access_size, &raw)) {
                    return false;
                }
                uint64_t value = raw;
                if (d->ldst_kind == VORTEX_LDST_LOAD_SIGN64 || d->ldst_kind == VORTEX_LDST_LOAD_SIGN32) {
                    uint32_t bits = d->access_size * 8u;
                    int64_t signed_value = (int64_t)(raw << (64u - bits)) >> (64u - bits);
                    value = d->ldst_kind == VORTEX_LDST_LOAD_SIGN64 ? (uint64_t)signed_value
                                                                   : (uint64_t)(uint32_t)(int32_t)signed_value;
                }
                vortex_set_reg(cpu, d->rt, value, true);
            }

            if (d->writeback) {
                uint64_t new_base = (uint64_t)((int64_t)base + d->writeback_offset);
                vortex_set_reg_sp(cpu, d->rn, new_base, true);
            }
            break;
        }

        case VORTEX_OP_B:
            next_pc = d->target;
            break;

        case VORTEX_OP_BL:
            vortex_set_reg_sp(cpu, 30u, next_pc, true);
            next_pc = d->target;
            break;

        case VORTEX_OP_B_COND:
            if (vortex_condition_holds(cpu, d->cond)) {
                next_pc = d->target;
            }
            break;

        case VORTEX_OP_CBZ: {
            uint64_t value = vortex_reg(cpu, d->rt);
            if (!d->is64) {
                value &= 0xFFFFFFFFull;
            }
            if (value == 0u) {
                next_pc = d->target;
            }
            break;
        }

        case VORTEX_OP_CBNZ: {
            uint64_t value = vortex_reg(cpu, d->rt);
            if (!d->is64) {
                value &= 0xFFFFFFFFull;
            }
            if (value != 0u) {
                next_pc = d->target;
            }
            break;
        }

        case VORTEX_OP_TBZ: {
            uint64_t value = vortex_reg(cpu, d->rt);
            bool set = ((value >> d->shift_amount) & 1u) != 0u;
            if (!set) {
                next_pc = d->target;
            }
            break;
        }

        case VORTEX_OP_TBNZ: {
            uint64_t value = vortex_reg(cpu, d->rt);
            bool set = ((value >> d->shift_amount) & 1u) != 0u;
            if (set) {
                next_pc = d->target;
            }
            break;
        }

        case VORTEX_OP_BR:
            next_pc = vortex_reg(cpu, d->rn);
            break;

        case VORTEX_OP_BLR: {
            uint64_t target = vortex_reg(cpu, d->rn);
            vortex_set_reg_sp(cpu, 30u, next_pc, true);
            next_pc = target;
            break;
        }

        case VORTEX_OP_RET:
            next_pc = vortex_reg(cpu, d->rn);
            break;

        default:
            return vortex_fail(cpu, VORTEX_CPU_ERROR_UNIMPLEMENTED, d->raw, cpu->pc, "unimplemented opcode");
    }

    cpu->pc = next_pc;
    cpu->instructions_executed += 1u;
    return true;
}

// MARK: - Step / run

bool vortex_cpu_step(vortex_cpu *cpu)
{
    if (cpu == NULL) {
        return false;
    }
    if (cpu->halted) {
        return false;
    }

    uint64_t pc = cpu->pc;
    vortex_decoded decoded;
    if (!vortex_fetch_decoded(cpu, pc, &decoded)) {
        return false;
    }
    return vortex_execute(cpu, &decoded);
}

size_t vortex_cpu_run(vortex_cpu *cpu, size_t max_instructions)
{
    if (cpu == NULL || max_instructions == 0u) {
        return 0u;
    }

    bool started_on_breakpoint = vortex_cpu_has_breakpoint(cpu, cpu->pc);
    size_t executed = 0u;
    double start = vortex_now_precise_seconds();

    for (size_t index = 0; index < max_instructions; index += 1u) {
        if (cpu->halted) {
            break;
        }
        if (executed > 0u || !started_on_breakpoint) {
            if (vortex_cpu_has_breakpoint(cpu, cpu->pc)) {
                break;
            }
        }
        if (!vortex_cpu_step(cpu)) {
            break;
        }
        executed += 1u;
    }

    double elapsed = vortex_now_precise_seconds() - start;
    if (executed >= 32u && elapsed > 0.0) {
        cpu->instructions_per_second = (uint64_t)((double)executed / elapsed);
    }

    return executed;
}

// MARK: - Disassembly

static void vortex_register_name(char *buffer, size_t capacity, uint32_t index, bool is64, bool sp_allowed)
{
    if (index == 31u) {
        if (sp_allowed) {
            snprintf(buffer, capacity, "%s", is64 ? "sp" : "wsp");
        } else {
            snprintf(buffer, capacity, "%s", is64 ? "xzr" : "wzr");
        }
        return;
    }
    snprintf(buffer, capacity, "%c%u", is64 ? 'x' : 'w', index);
}

size_t vortex_cpu_disassemble(uint32_t instruction, uint64_t pc, char *buffer, size_t capacity)
{
    if (buffer == NULL || capacity == 0u) {
        return 0u;
    }

    char text[96];
    text[0] = '\0';

    vortex_decoded decoded;
    memset(&decoded, 0, sizeof(decoded));
    bool known = vortex_decode(NULL, instruction, pc, &decoded);

    if (!known) {
        snprintf(text, sizeof(text), ".inst 0x%08x", instruction);
        snprintf(buffer, capacity, "%s", text);
        return strlen(buffer);
    }

    char rd[8];
    char rn[8];
    char rm[8];
    vortex_register_name(rd, sizeof(rd), decoded.rd, decoded.is64, true);
    vortex_register_name(rn, sizeof(rn), decoded.rn, decoded.is64, true);
    vortex_register_name(rm, sizeof(rm), decoded.rm, decoded.is64, false);

    switch (decoded.op) {
        case VORTEX_OP_NOP:
            snprintf(text, sizeof(text), "nop");
            break;
        case VORTEX_OP_ADD_IMM:
            if (decoded.sets_flags && decoded.rd == 31u) {
                snprintf(text, sizeof(text), "cmn %s, #%lld", rn, (long long)decoded.immediate);
            } else {
                snprintf(text, sizeof(text), "%s %s, %s, #%lld",
                         decoded.sets_flags ? "adds" : "add", rd, rn, (long long)decoded.immediate);
            }
            break;
        case VORTEX_OP_SUB_IMM:
            if (decoded.sets_flags && decoded.rd == 31u) {
                snprintf(text, sizeof(text), "cmp %s, #%lld", rn, (long long)decoded.immediate);
            } else {
                snprintf(text, sizeof(text), "%s %s, %s, #%lld",
                         decoded.sets_flags ? "subs" : "sub", rd, rn, (long long)decoded.immediate);
            }
            break;
        case VORTEX_OP_MOVZ:
            if (decoded.immediate == 0) {
                snprintf(text, sizeof(text), "mov %s, #0", rd);
            } else {
                snprintf(text, sizeof(text), "mov %s, #%lld", rd, (long long)decoded.immediate);
            }
            break;
        case VORTEX_OP_MOVN:
            snprintf(text, sizeof(text), "movn %s, #0x%llx", rd, (unsigned long long)decoded.immediate);
            break;
        case VORTEX_OP_MOVK:
            snprintf(text, sizeof(text), "movk %s, #0x%llx, lsl #%u",
                     rd, (unsigned long long)decoded.immediate, decoded.shift_amount);
            break;
        case VORTEX_OP_AND_IMM:
            snprintf(text, sizeof(text), "and %s, %s, #0x%llx", rd, rn, (unsigned long long)decoded.immediate);
            break;
        case VORTEX_OP_ORR_IMM:
            snprintf(text, sizeof(text), "orr %s, %s, #0x%llx", rd, rn, (unsigned long long)decoded.immediate);
            break;
        case VORTEX_OP_EOR_IMM:
            snprintf(text, sizeof(text), "eor %s, %s, #0x%llx", rd, rn, (unsigned long long)decoded.immediate);
            break;
        case VORTEX_OP_ANDS_IMM:
            snprintf(text, sizeof(text), "ands %s, %s, #0x%llx", rd, rn, (unsigned long long)decoded.immediate);
            break;
        case VORTEX_OP_ADR:
        case VORTEX_OP_ADRP: {
            uint64_t base = decoded.op == VORTEX_OP_ADRP ? (pc & ~0xFFFull) : pc;
            snprintf(text, sizeof(text), "%s %s, #0x%llx",
                     decoded.op == VORTEX_OP_ADRP ? "adrp" : "adr", rd,
                     (unsigned long long)((uint64_t)((int64_t)base + decoded.immediate)));
            break;
        }
        case VORTEX_OP_ADD_REG:
        case VORTEX_OP_SUB_REG: {
            const char *name = decoded.op == VORTEX_OP_ADD_REG ? (decoded.sets_flags ? "adds" : "add")
                                                               : (decoded.sets_flags ? "subs" : "sub");
            if (decoded.sets_flags && decoded.rd == 31u) {
                snprintf(text, sizeof(text), "cmp %s, %s", rn, rm);
            } else {
                snprintf(text, sizeof(text), "%s %s, %s, %s", name, rd, rn, rm);
            }
            break;
        }
        case VORTEX_OP_AND_REG:
        case VORTEX_OP_ORR_REG:
        case VORTEX_OP_EOR_REG:
        case VORTEX_OP_ANDS_REG: {
            const char *base = decoded.op == VORTEX_OP_AND_REG ? "and"
                             : (decoded.op == VORTEX_OP_ORR_REG ? "orr"
                             : (decoded.op == VORTEX_OP_EOR_REG ? "eor" : "ands"));
            if (decoded.sets_flags && decoded.op == VORTEX_OP_ANDS_REG) {
                base = "tst";
            } else if (decoded.invert) {
                base = decoded.op == VORTEX_OP_AND_REG ? "bic"
                     : (decoded.op == VORTEX_OP_ORR_REG ? "orn" : "eon");
            }
            if (decoded.op == VORTEX_OP_ANDS_REG && decoded.rd == 31u) {
                snprintf(text, sizeof(text), "tst %s, %s", rn, rm);
            } else {
                snprintf(text, sizeof(text), "%s %s, %s, %s", base, rd, rn, rm);
            }
            break;
        }
        case VORTEX_OP_LSLV:
            snprintf(text, sizeof(text), "lslv %s, %s, %s", rd, rn, rm);
            break;
        case VORTEX_OP_LSRV:
            snprintf(text, sizeof(text), "lsrv %s, %s, %s", rd, rn, rm);
            break;
        case VORTEX_OP_ASRV:
            snprintf(text, sizeof(text), "asrv %s, %s, %s", rd, rn, rm);
            break;
        case VORTEX_OP_MADD:
            if (decoded.ra == 31u) {
                snprintf(text, sizeof(text), "mul %s, %s, %s", rd, rn, rm);
            } else {
                char ra[8];
                vortex_register_name(ra, sizeof(ra), decoded.ra, decoded.is64, false);
                snprintf(text, sizeof(text), "madd %s, %s, %s, %s", rd, rn, rm, ra);
            }
            break;
        case VORTEX_OP_MSUB:
            snprintf(text, sizeof(text), "msub %s, %s, %s, x%u", rd, rn, rm, decoded.ra);
            break;
        case VORTEX_OP_UDIV:
            snprintf(text, sizeof(text), "udiv %s, %s, %s", rd, rn, rm);
            break;
        case VORTEX_OP_SDIV:
            snprintf(text, sizeof(text), "sdiv %s, %s, %s", rd, rn, rm);
            break;
        case VORTEX_OP_CSEL:
        case VORTEX_OP_CSINC:
        case VORTEX_OP_CSINV:
        case VORTEX_OP_CSNEG: {
            const char *name = decoded.op == VORTEX_OP_CSEL ? "csel"
                             : decoded.op == VORTEX_OP_CSINC ? "csinc"
                             : decoded.op == VORTEX_OP_CSINV ? "csinv" : "csneg";
            snprintf(text, sizeof(text), "%s %s, %s, %s, %s", name, rd, rn, rm,
                     vortex_condition_name(decoded.cond));
            break;
        }
        case VORTEX_OP_CLZ:
            snprintf(text, sizeof(text), "clz %s, %s", rd, rn);
            break;
        case VORTEX_OP_LDST: {
            char rt[8];
            vortex_register_name(rt, sizeof(rt), decoded.rt, decoded.is64 || decoded.ldst_kind != VORTEX_LDST_STORE, false);
            const char *mnemonic;
            bool is64 = decoded.access_size == 8u;
            switch (decoded.ldst_kind) {
                case VORTEX_LDST_STORE:
                    mnemonic = decoded.access_size == 1u ? "strb" : (decoded.access_size == 2u ? "strh" : (decoded.access_size == 4u ? "str" : "str"));
                    break;
                case VORTEX_LDST_LOAD_ZERO:
                    mnemonic = decoded.access_size == 1u ? "ldrb" : (decoded.access_size == 2u ? "ldrh" : "ldr");
                    break;
                case VORTEX_LDST_LOAD_SIGN64:
                    mnemonic = decoded.access_size == 1u ? "ldrsb" : (decoded.access_size == 2u ? "ldrsh" : "ldrsw");
                    break;
                default:
                    mnemonic = decoded.access_size == 1u ? "ldrsb" : (decoded.access_size == 2u ? "ldrsh" : "ldr");
                    break;
            }
            (void)is64;
            if (decoded.writeback && decoded.offset == 0) {
                snprintf(text, sizeof(text), "%s %s, [%s], #%lld", mnemonic, rt, rn, (long long)decoded.writeback_offset);
            } else if (decoded.writeback) {
                snprintf(text, sizeof(text), "%s %s, [%s, #%lld]!", mnemonic, rt, rn, (long long)decoded.offset);
            } else if (decoded.offset == 0) {
                snprintf(text, sizeof(text), "%s %s, [%s]", mnemonic, rt, rn);
            } else {
                snprintf(text, sizeof(text), "%s %s, [%s, #%lld]", mnemonic, rt, rn, (long long)decoded.offset);
            }
            break;
        }
        case VORTEX_OP_B:
            snprintf(text, sizeof(text), "b #0x%llx", (unsigned long long)decoded.target);
            break;
        case VORTEX_OP_BL:
            snprintf(text, sizeof(text), "bl #0x%llx", (unsigned long long)decoded.target);
            break;
        case VORTEX_OP_B_COND:
            snprintf(text, sizeof(text), "b.%s #0x%llx", vortex_condition_name(decoded.cond),
                     (unsigned long long)decoded.target);
            break;
        case VORTEX_OP_CBZ:
        case VORTEX_OP_CBNZ: {
            char rt[8];
            vortex_register_name(rt, sizeof(rt), decoded.rt, decoded.is64, false);
            snprintf(text, sizeof(text), "%s %s, #0x%llx",
                     decoded.op == VORTEX_OP_CBZ ? "cbz" : "cbnz", rt, (unsigned long long)decoded.target);
            break;
        }
        case VORTEX_OP_TBZ:
        case VORTEX_OP_TBNZ: {
            char rt[8];
            vortex_register_name(rt, sizeof(rt), decoded.rt, true, false);
            snprintf(text, sizeof(text), "%s %s, #%u, #0x%llx",
                     decoded.op == VORTEX_OP_TBZ ? "tbz" : "tbnz", rt, decoded.shift_amount,
                     (unsigned long long)decoded.target);
            break;
        }
        case VORTEX_OP_BR:
            snprintf(text, sizeof(text), "br %s", rn);
            break;
        case VORTEX_OP_BLR:
            snprintf(text, sizeof(text), "blr %s", rn);
            break;
        case VORTEX_OP_RET:
            snprintf(text, sizeof(text), "ret %s", rn);
            break;
        default:
            snprintf(text, sizeof(text), ".inst 0x%08x", instruction);
            break;
    }

    snprintf(buffer, capacity, "%s", text);
    return strlen(buffer);
}
