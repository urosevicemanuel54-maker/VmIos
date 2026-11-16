//
//  PerformanceMonitor.swift
//  Vortex
//
//  Host-side measurements: memory footprint, thermal state and formatting.
//  No value in this file is estimated; anything unavailable is reported as
//  unavailable.
//

import Foundation
import Darwin

/// Thermal pressure reported by the system.
enum ThermalLevel: String {
    case nominal
    case fair
    case serious
    case critical

    init(thermalState: ProcessInfo.ThermalState) {
        switch thermalState {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

/// Read-only view of everything the dashboard draws.
struct PerformanceSnapshot {
    var measuredFPS: Double = 0
    var frameTimeMs: Double = 0
    var frameTimeSamples: [Double] = []
    var gpuTimeMs: Double?
    var budgetMs: Double = 16.7
    var memoryFootprintBytes: UInt64 = 0
    var thermal: ThermalLevel = .nominal
    var isLowPowerMode: Bool = false
    var framesPresented: UInt64 = 0
    var framesSkipped: UInt64 = 0
    var instructionsExecuted: UInt64 = 0
    var emulationErrors: UInt64 = 0
    var guestTicks: UInt64 = 0
    var guestWidth: Int = 1280
    var guestHeight: Int = 832
    var renderScale: Double = 1.0
    var displayRefreshRate: Double = 60

    static let placeholder = PerformanceSnapshot()
}

/// Number formatting shared by the dashboard and the tests.
enum MetricsFormatting {
    static func fps(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "--" }
        return String(format: "%.1f", value)
    }

    static func milliseconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--" }
        return String(format: "%.2f", value)
    }

    static func scale(_ value: Double) -> String {
        String(format: "%.2fx", value)
    }

    static func megabytesValue(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576.0)
    }

    static func megabytes(_ bytes: UInt64) -> String {
        "\(megabytesValue(bytes)) MB"
    }

    static func counter(_ value: UInt64) -> String {
        String(value)
    }
}

/// The app's phys_footprint as reported by the kernel.
enum MemoryProbe {
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}
