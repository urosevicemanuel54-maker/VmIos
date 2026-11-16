//
//  vortex_core.h
//  Vortex
//
//  Public API of the native emulator core.
//
//  The core is owned across the C/Swift boundary by a single opaque handle.
//  Swift never sees the layout of `vortex_core`; it only creates it, feeds it
//  wall-clock deltas and reads back measured counters.
//

#ifndef VORTEX_CORE_H
#define VORTEX_CORE_H

#include <stdbool.h>
#include <stdint.h>

#include "vortex_cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Version of the C ABI. Bump whenever the struct layouts below change.
#define VORTEX_CORE_ABI_VERSION 1u

/// Rate of the guest's fixed-step clock, in ticks per second.
#define VORTEX_GUEST_TICK_HZ 60u

/// Upper bound on how many fixed steps a single advance() may execute.
/// Frames that arrive late therefore drop guest time instead of spiralling.
#define VORTEX_CORE_MAX_STEPS_PER_ADVANCE 8u

/// Opaque handle to a core instance.
typedef struct vortex_core vortex_core;

/// Contiguous snapshot of the core's measured state.
typedef struct vortex_core_stats {
    uint64_t frames_presented;
    uint64_t frames_skipped;
    uint64_t guest_ticks;
    uint64_t instructions_executed;
    uint64_t emulation_errors;
    uint32_t guest_width;
    uint32_t guest_height;
    uint32_t tick_hz;
} vortex_core_stats;

/// Allocates a core with the default guest display geometry and a 60 Hz clock.
/// Returns NULL when allocation fails.
vortex_core *vortex_core_create(void);

/// Releases a core. Passing NULL is a no-op.
void vortex_core_destroy(vortex_core *core);

/// Clears the clock accumulator and every counter.
void vortex_core_reset(vortex_core *core);

/// Sets the guest raster size. Returns false for degenerate or oversized sizes.
bool vortex_core_set_guest_size(vortex_core *core, uint32_t width, uint32_t height);

/// Feeds wall-clock time into the fixed-step clock.
/// Returns true when at least one guest tick was executed.
bool vortex_core_advance(vortex_core *core, double delta_seconds);

void vortex_core_note_frame_presented(vortex_core *core);
void vortex_core_note_frame_skipped(vortex_core *core);
void vortex_core_note_error(vortex_core *core);

/// Reads the current counters.
vortex_core_stats vortex_core_get_stats(const vortex_core *core);

/// Normalised horizontal position (0..1) of the test-pattern marker.
/// Derived from the guest clock, so the marker only moves while the guest runs.
float vortex_core_marker_position(const vortex_core *core);

uint32_t vortex_core_abi_version(void);

/// Guest CPU owned by this core. Valid until the core is destroyed.
vortex_cpu *vortex_core_get_cpu(vortex_core *core);

/// NUL-terminated, statically allocated build label.
const char *vortex_core_build_label(void);

#ifdef __cplusplus
}
#endif

#endif /* VORTEX_CORE_H */
