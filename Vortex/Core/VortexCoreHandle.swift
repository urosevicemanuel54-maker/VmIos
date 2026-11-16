//
//  VortexCoreHandle.swift
//  Vortex
//
//  Swift ownership of the opaque C core handle.
//

import Foundation

/// Measured counters reported by the C core.
struct VortexCoreStats {
    var framesPresented: UInt64
    var framesSkipped: UInt64
    var guestTicks: UInt64
    var instructionsExecuted: UInt64
    var emulationErrors: UInt64
    var guestWidth: Int
    var guestHeight: Int
    var tickHz: Int

    static let zero = VortexCoreStats(framesPresented: 0,
                                     framesSkipped: 0,
                                     guestTicks: 0,
                                     instructionsExecuted: 0,
                                     emulationErrors: 0,
                                     guestWidth: 1280,
                                     guestHeight: 832,
                                     tickHz: Int(VORTEX_GUEST_TICK_HZ))
}

/// Sole owner of a `vortex_core` instance.
///
/// The handle is created once per app launch and destroyed on deinit. Every
/// call must happen on the main thread: the render loop is the only caller.
final class VortexCoreHandle {
    private var handle = vortex_core_create()
    private var cpuStorage: GuestCPU?

    init() {}

    deinit {
        cpuStorage?.detach()
        cpuStorage = nil
        if let handle {
            vortex_core_destroy(handle)
        }
        handle = nil
    }

    /// Guest CPU owned by the core. Created on first use.
    var cpu: GuestCPU {
        if let existing = cpuStorage {
            return existing
        }
        let created = GuestCPU(pointer: handle.map { vortex_core_get_cpu($0) })
        cpuStorage = created
        return created
    }

    var isReady: Bool { handle != nil }

    static var abiVersion: UInt32 { vortex_core_abi_version() }

    static var buildLabel: String {
        guard let label = vortex_core_build_label() else { return "unknown" }
        return String(cString: label)
    }

    var stats: VortexCoreStats {
        guard let handle else { return .zero }
        let raw = vortex_core_get_stats(handle)
        return VortexCoreStats(framesPresented: raw.frames_presented,
                               framesSkipped: raw.frames_skipped,
                               guestTicks: raw.guest_ticks,
                               instructionsExecuted: raw.instructions_executed,
                               emulationErrors: raw.emulation_errors,
                               guestWidth: Int(raw.guest_width),
                               guestHeight: Int(raw.guest_height),
                               tickHz: Int(raw.tick_hz))
    }

    /// Normalised horizontal position of the test-pattern marker.
    var markerPosition: Float {
        guard let handle else { return 0.12 }
        return vortex_core_marker_position(handle)
    }

    @discardableResult
    func advance(delta: Double) -> Bool {
        guard let handle else { return false }
        return vortex_core_advance(handle, delta)
    }

    func noteFramePresented() {
        guard let handle else { return }
        vortex_core_note_frame_presented(handle)
    }

    func noteFrameSkipped() {
        guard let handle else { return }
        vortex_core_note_frame_skipped(handle)
    }

    func noteError() {
        guard let handle else { return }
        vortex_core_note_error(handle)
    }

    func reset() {
        guard let handle else { return }
        vortex_core_reset(handle)
    }

    @discardableResult
    func setGuestSize(width: Int, height: Int) -> Bool {
        guard let handle, width > 0, height > 0 else { return false }
        return vortex_core_set_guest_size(handle, UInt32(width), UInt32(height))
    }
}
