//
//  JITSystemInfo.swift
//  Vortex
//
//  Host capability detection. Every value is either read from the system or
//  explicitly reported as unknown; nothing is assumed from the iOS version.
//

import Foundation
import UIKit
import Darwin

enum DeveloperModeStatus: Equatable {
    /// iOS exposes no public Developer Mode query. A development-signed app
    /// carrying get-task-allow can only be running here with Developer Mode
    /// accepted, so that combination is reported as an inference, not a fact.
    case inferredEnabled
    case unknown

    var label: String {
        switch self {
        case .inferredEnabled: return "Enabled (inferred)"
        case .unknown: return "Unknown"
        }
    }

    var detail: String {
        switch self {
        case .inferredEnabled:
            return "A development-signed app is running, which requires Developer Mode."
        case .unknown:
            return "iOS has no public Developer Mode query; enable it in Settings › Privacy & Security."
        }
    }
}

enum TXMStatus: Equatable {
    case present
    case notPresent
    case unknown

    var label: String {
        switch self {
        case .present: return "Present"
        case .notPresent: return "Not present"
        case .unknown: return "Unknown"
        }
    }

    var detail: String {
        switch self {
        case .present:
            return "Each executable region must be prepared through the JIT script."
        case .notPresent:
            return "Debugger attachment alone enables JIT."
        case .unknown:
            return "StikJIT reports TXM presence; this build does not embed StikJIT, so it cannot be determined."
        }
    }
}

enum JITMemoryStatus: Equatable {
    case available
    case denied

    var label: String {
        switch self {
        case .available: return "Executable memory available"
        case .denied: return "Executable memory denied"
        }
    }
}

enum VPNStatus: Equatable {
    case connected(endpoint: String)
    case endpointUnreachable(endpoint: String)
    case noTunnel

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .endpointUnreachable: return "Tunnel present, endpoint unreachable"
        case .noTunnel: return "No loopback tunnel"
        }
    }

    var detail: String {
        switch self {
        case .connected(let endpoint):
            return "TCP connection to \(endpoint) completed."
        case .endpointUnreachable(let endpoint):
            return "A utun interface exists but \(endpoint) did not accept a connection."
        case .noTunnel:
            return "Connect LocalDevVPN before enabling JIT. No utun interface with an address was found."
        }
    }

    var isVerifiedConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct JITSystemInfo {
    let osVersion: String
    let osMajor: Int
    let osMinor: Int
    let osPatch: Int
    let deviceIdentifier: String
    let architecture: String
    let hasGetTaskAllow: Bool
    let isDebugged: Bool
    let jitMemory: JITMemoryStatus
    let developerMode: DeveloperModeStatus
    let txm: TXMStatus

    /// StikJIT supports iOS 17.4 and later.
    static func supportsStikJIT(major: Int, minor: Int) -> Bool {
        major > 17 || (major == 17 && minor >= 4)
    }

    var supportsStikJIT: Bool {
        Self.supportsStikJIT(major: osMajor, minor: osMinor)
    }

    var isJITActive: Bool {
        isDebugged && jitMemory == .available
    }

    /// Debugger attachment alone is documented as sufficient below iOS 26.
    /// From iOS 26 each executable region must be prepared by the JIT script.
    var canVerifyExecutionInProcess: Bool {
        osMajor < 26
    }

    static func current() -> JITSystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return JITSystemInfo(osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                             osMajor: version.majorVersion,
                             osMinor: version.minorVersion,
                             osPatch: version.patchVersion,
                             deviceIdentifier: Self.hardwareIdentifier(),
                             architecture: Self.architectureName(),
                             hasGetTaskAllow: JITHostProbe.hasGetTaskAllow,
                             isDebugged: JITHostProbe.isDebugged,
                             jitMemory: JITHostProbe.jitMemoryAvailable ? .available : .denied,
                             developerMode: JITHostProbe.hasGetTaskAllow ? .inferredEnabled : .unknown,
                             txm: .unknown)
    }

    static func architectureName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &systemInfo.machine) { buffer -> String in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// Swift surface for the C host probes.
enum JITHostProbe {
    static var hasGetTaskAllow: Bool {
        vortex_host_has_get_task_allow()
    }

    static var isDebugged: Bool {
        vortex_host_is_debugged()
    }

    static var jitMemoryAvailable: Bool {
        vortex_host_jit_memory_available()
    }

    static func tcpReachable(host: String, port: Int32, timeoutMilliseconds: Int32) -> Bool {
        host.withCString { pointer in
            vortex_host_tcp_reachable(pointer, port, timeoutMilliseconds)
        }
    }

    struct SelfTestOutcome {
        let allocated: Bool
        let executed: Bool
        let value: Int
    }

    /// Allocates JIT memory and, only when asked, executes self-test code.
    static func selfTest(executeCode: Bool) -> SelfTestOutcome {
        var value: Int32 = 0
        let located = vortex_jit_self_test(executeCode, &value)
        let valueAsInt = Int(value)
        return SelfTestOutcome(allocated: located,
                               executed: executeCode && located && valueAsInt == 42,
                               value: valueAsInt)
    }
}

enum VPNProbe {
    /// LocalDevVPN's documented Remote Pairing endpoint.
    static let endpointHost = "10.7.0.1"
    static let endpointPort: Int32 = 49152

    static var endpointDescription: String {
        "\(endpointHost):\(endpointPort)"
    }

    static func detect() -> VPNStatus {
        guard hasLoopbackTunnel() else { return .noTunnel }
        if JITHostProbe.tcpReachable(host: endpointHost,
                                     port: endpointPort,
                                     timeoutMilliseconds: 400) {
            return .connected(endpoint: endpointDescription)
        }
        return .endpointUnreachable(endpoint: endpointDescription)
    }

    /// True when a utun interface currently has an IPv4 address.
    static func hasLoopbackTunnel() -> Bool {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return false }
        defer { freeifaddrs(addressList) }

        var found = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            let name = String(cString: interface.pointee.ifa_name)
            if name.hasPrefix("utun"), interface.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
                found = true
                break
            }
            cursor = interface.pointee.ifa_next
        }
        return found
    }
}
