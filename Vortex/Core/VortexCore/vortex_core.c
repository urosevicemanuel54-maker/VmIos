//
//  vortex_core.c
//  Vortex
//
//  Implementation of the native emulator core: the guest clock, the guest
//  raster geometry and the counters the performance dashboard reports.
//
//  What is implemented here is real and measured: a fixed-step clock that
//  accumulates host time and executes at most VORTEX_CORE_MAX_STEPS_PER_ADVANCE
//  steps per call, plus counters for frames and errors.
//
//  What is not implemented yet: instruction execution. The CPU interpreter is
//  the next milestone, so instructions_executed and emulation_errors stay at
//  zero until something genuinely increments them.
//

#include "vortex_core.h"

#include <math.h>
#include <stdlib.h>

#define VORTEX_DEFAULT_GUEST_WIDTH 1280u
#define VORTEX_DEFAULT_GUEST_HEIGHT 832u
#define VORTEX_MARKER_PERIOD_SECONDS 6.0
#define VORTEX_MAX_FRAME_DELTA_SECONDS 0.25

struct vortex_core {
    uint32_t guest_width;
    uint32_t guest_height;
    double step_seconds;
    double accumulator;
    uint64_t frames_presented;
    uint64_t frames_skipped;
    uint64_t guest_ticks;
    uint64_t instructions_executed;
    uint64_t emulation_errors;
    vortex_cpu *cpu;
};

static double vortex_fixed_step_seconds(void)
{
    return 1.0 / (double)VORTEX_GUEST_TICK_HZ;
}

vortex_core *vortex_core_create(void)
{
    vortex_core *core = (vortex_core *)calloc(1, sizeof(*core));
    if (core == NULL) {
        return NULL;
    }

    core->guest_width = VORTEX_DEFAULT_GUEST_WIDTH;
    core->guest_height = VORTEX_DEFAULT_GUEST_HEIGHT;
    core->step_seconds = vortex_fixed_step_seconds();
    core->accumulator = 0.0;

    core->cpu = vortex_cpu_create();
    if (core->cpu == NULL) {
        free(core);
        return NULL;
    }
    return core;
}

void vortex_core_destroy(vortex_core *core)
{
    if (core == NULL) {
        return;
    }
    vortex_cpu_destroy(core->cpu);
    core->cpu = NULL;
    free(core);
}

void vortex_core_reset(vortex_core *core)
{
    if (core == NULL) {
        return;
    }
    core->accumulator = 0.0;
    core->frames_presented = 0;
    core->frames_skipped = 0;
    core->guest_ticks = 0;
    core->instructions_executed = 0;
    core->emulation_errors = 0;
    if (core->cpu != NULL) {
        vortex_cpu_reset(core->cpu);
    }
}

bool vortex_core_set_guest_size(vortex_core *core, uint32_t width, uint32_t height)
{
    if (core == NULL) {
        return false;
    }
    if (width < 16u || height < 16u || width > 8192u || height > 8192u) {
        return false;
    }
    core->guest_width = width;
    core->guest_height = height;
    return true;
}

bool vortex_core_advance(vortex_core *core, double delta_seconds)
{
    if (core == NULL) {
        return false;
    }
    /* The comparison also rejects NaN and negative deltas. */
    if (!(delta_seconds > 0.0)) {
        return false;
    }
    if (delta_seconds > VORTEX_MAX_FRAME_DELTA_SECONDS) {
        delta_seconds = VORTEX_MAX_FRAME_DELTA_SECONDS;
    }

    core->accumulator += delta_seconds;

    uint32_t steps = 0;
    while (core->accumulator >= core->step_seconds &&
           steps < VORTEX_CORE_MAX_STEPS_PER_ADVANCE) {
        core->accumulator -= core->step_seconds;
        core->guest_ticks += 1u;
        steps += 1u;
    }

    if (steps == VORTEX_CORE_MAX_STEPS_PER_ADVANCE && core->accumulator >= core->step_seconds) {
        /* Too far behind to catch up: drop the debt instead of stalling. */
        core->accumulator = fmod(core->accumulator, core->step_seconds);
    }

    return steps > 0u;
}

void vortex_core_note_frame_presented(vortex_core *core)
{
    if (core == NULL) {
        return;
    }
    core->frames_presented += 1u;
}

void vortex_core_note_frame_skipped(vortex_core *core)
{
    if (core == NULL) {
        return;
    }
    core->frames_skipped += 1u;
}

void vortex_core_note_error(vortex_core *core)
{
    if (core == NULL) {
        return;
    }
    core->emulation_errors += 1u;
}

vortex_core_stats vortex_core_get_stats(const vortex_core *core)
{
    vortex_core_stats stats;

    if (core == NULL) {
        stats.frames_presented = 0;
        stats.frames_skipped = 0;
        stats.guest_ticks = 0;
        stats.instructions_executed = 0;
        stats.emulation_errors = 0;
        stats.guest_width = VORTEX_DEFAULT_GUEST_WIDTH;
        stats.guest_height = VORTEX_DEFAULT_GUEST_HEIGHT;
        stats.tick_hz = VORTEX_GUEST_TICK_HZ;
        return stats;
    }

    stats.frames_presented = core->frames_presented;
    stats.frames_skipped = core->frames_skipped;
    stats.guest_ticks = core->guest_ticks;
    stats.instructions_executed = core->instructions_executed;
    stats.emulation_errors = core->emulation_errors;
    if (core->cpu != NULL) {
        vortex_cpu_snapshot snapshot;
        vortex_cpu_copy_snapshot(core->cpu, &snapshot);
        stats.instructions_executed += snapshot.instructions_executed;
        stats.emulation_errors += snapshot.error_count;
    }
    stats.guest_width = core->guest_width;
    stats.guest_height = core->guest_height;
    stats.tick_hz = VORTEX_GUEST_TICK_HZ;
    return stats;
}

vortex_cpu *vortex_core_get_cpu(vortex_core *core)
{
    return core == NULL ? NULL : core->cpu;
}

float vortex_core_marker_position(const vortex_core *core)
{
    if (core == NULL) {
        return 0.12f;
    }

    const uint64_t period_ticks = (uint64_t)(VORTEX_MARKER_PERIOD_SECONDS * (double)VORTEX_GUEST_TICK_HZ);
    if (period_ticks == 0u) {
        return 0.5f;
    }

    double phase = (double)(core->guest_ticks % period_ticks) / (double)period_ticks;
    double sweep = phase < 0.5 ? phase * 2.0 : (1.0 - phase) * 2.0;

    /* Keep the marker inside the raster so it never clips at the edges. */
    return (float)(0.12 + sweep * 0.76);
}

uint32_t vortex_core_abi_version(void)
{
    return VORTEX_CORE_ABI_VERSION;
}

const char *vortex_core_build_label(void)
{
    return "Vortex core 0.1 (display only)";
}
