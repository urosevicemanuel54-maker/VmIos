//
//  JITCoordinator.swift
//  Vortex
//
//  Preflight, method selection and activation reporting for JIT.
//
//  Implemented methods:
//    • Wait for Debugger — attach from Xcode or another debugger.
//    • StikDebug        — open the documented stikdebug:// request.
//    • Built-in StikJIT — not embedded in this build (see SETUP.md). Reported
//      as unavailable rather than silently falling back to another method.
//

import Foundation
import UIKit

enum JITMethod: String, CaseIterable, Identifiable {
    case stikDebug
    case waitForDebugger
    case builtInStikJIT

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stikDebug: return "StikDebug"
        case .waitForDebugger: return "Wait for Debugger"
        case .builtInStikJIT: return "Built-in StikJIT"
        }
    }

    var availability: JITMethodAvailability {
        switch self {
        case .stikDebug, .waitForDebugger:
            return .available
        case .builtInStikJIT:
            return .unavailable("StikJIT.xcframework and its helper app extension are not part of this build. Use StikDebug or Wait for Debugger, or follow SETUP.md to embed the framework in a helper extension.")
        }
    }

    var requiresPairingFile: Bool {
        self == .stikDebug || self == .builtInStikJIT
    }
}

enum JITMethodAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

enum JITStepState: Equatable {
    case pass
    case warn
    case fail
    case info
}

struct JITPreflightStep: Identifiable, Equatable {
    let id: String
    let title: String
    let state: JITStepState
    let detail: String
}

enum JITActivationResult: Equatable {
    case idle
    case running(String)
    case succeeded(String)
    case unverified(String)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .idle, .running: return false
        case .succeeded, .unverified, .failed: return true
        }
    }

    var label: String {
        switch self {
        case .idle: return "Not attempted"
        case .running: return "In progress"
        case .succeeded: return "JIT activated"
        case .unverified: return "Attached, unverified"
        case .failed: return "Failed"
        }
    }

    var detail: String {
        switch self {
        case .idle: return "No activation has been attempted in this session."
        case .running(let step): return step
        case .succeeded(let message): return message
        case .unverified(let message): return message
        case .failed(let message): return message
        }
    }
}

enum JITExecutionMode: Equatable {
    case jit(reason: String)
    case interpreter(reason: String)

    var label: String {
        switch self {
        case .jit: return "JIT"
        case .interpreter: return "Interpreter"
        }
    }

    var detail: String {
        switch self {
        case .jit(let reason): return reason
        case .interpreter(let reason): return reason
        }
    }
}

/// Builds the documented StikDebug request URL.
enum StikDebugLaunch {
    static let scheme = "stikdebug"
    static let scriptName = "universal.js"

    static func enableJITURL(bundleIdentifier: String,
                             processID: Int32,
                             scriptName: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "enable-jit"

        var items = [URLQueryItem(name: "bundle-id", value: bundleIdentifier),
                     URLQueryItem(name: "pid", value: String(processID))]
        if let scriptName {
            items.append(URLQueryItem(name: "script-name", value: scriptName))
        }
        components.queryItems = items
        return components.url
    }

    static var isInstalled: Bool {
        guard let url = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

final class JITCoordinator: ObservableObject {
    @Published private(set) var system: JITSystemInfo = JITSystemInfo.current()
    @Published private(set) var pairing: PairingStatus
    @Published private(set) var vpn: VPNStatus = .noTunnel
    @Published private(set) var activation: JITActivationResult = .idle
    @Published private(set) var preflight: [JITPreflightStep] = []
    @Published private(set) var lastActivationSummary: String?
    @Published private(set) var usesInterpreterOnly = false

    @Published var method: JITMethod {
        didSet {
            UserDefaults.standard.set(method.rawValue, forKey: Self.methodDefaultsKey)
            refresh()
        }
    }

    let store: PairingStore

    private static let methodDefaultsKey = "vortex.jit.method"
    private static let lastResultDefaultsKey = "vortex.jit.lastResult"

    private var pollTask: Task<Void, Never>?
    private var vpnTask: Task<Void, Never>?

    init(store: PairingStore = PairingStore()) {
        self.store = store
        self.pairing = store.status()

        if let raw = UserDefaults.standard.string(forKey: Self.methodDefaultsKey),
           let saved = JITMethod(rawValue: raw) {
            method = saved
        } else {
            method = .stikDebug
        }

        lastActivationSummary = UserDefaults.standard.string(forKey: Self.lastResultDefaultsKey)
        refresh()
    }

    deinit {
        pollTask?.cancel()
        vpnTask?.cancel()
    }

    // MARK: - Snapshot

    func refresh() {
        system = JITSystemInfo.current()
        pairing = store.status()
        preflight = makePreflight()

        vpnTask?.cancel()
        vpnTask = Task { @MainActor [weak self] in
            let status = await Task.detached(priority: .utility) { VPNProbe.detect() }.value
            self?.vpn = status
            self?.preflight = self?.makePreflight() ?? []
        }
    }

    var overallHeadline: String {
        if system.isJITActive { return "JIT active" }
        if case .failed = activation { return "JIT unavailable" }
        if !system.supportsStikJIT { return "JIT unavailable" }
        return "JIT not active"
    }

    var overallDetail: String {
        switch activation {
        case .succeeded(let message), .unverified(let message), .failed(let message):
            return message
        case .running(let step):
            return step
        case .idle:
            if system.isJITActive {
                return "This process is already debuggable and executable memory is permitted."
            }
            return "Run the setup checks, then enable JIT. Vortex falls back to its interpreter whenever JIT is not confirmed."
        }
    }

    var executionMode: JITExecutionMode {
        if usesInterpreterOnly {
            return .interpreter(reason: "JIT was skipped for this session.")
        }
        if system.isJITActive {
            return .jit(reason: "Executable memory is permitted and the process is debuggable.")
        }
        if case .succeeded = activation, system.jitMemory == .available {
            return .jit(reason: "JIT activation succeeded and executable memory is permitted.")
        }
        if !system.hasGetTaskAllow {
            return .interpreter(reason: "This installation has no get-task-allow entitlement, so JIT cannot be enabled.")
        }
        if !system.isDebugged {
            return .interpreter(reason: "No debugger is attached yet.")
        }
        return .interpreter(reason: "Debugger attached, but JIT was not confirmed.")
    }

    // MARK: - Preflight

    private func makePreflight() -> [JITPreflightStep] {
        var steps: [JITPreflightStep] = []

        steps.append(JITPreflightStep(id: "os",
                                      title: "iOS version",
                                      state: system.supportsStikJIT ? .pass : .fail,
                                      detail: system.supportsStikJIT
                                        ? "iOS \(system.osVersion) is supported by StikJIT (17.4+)."
                                        : "StikJIT needs iOS 17.4 or later; this device runs \(system.osVersion)."))

        let isArm64 = system.architecture == "arm64"
        steps.append(JITPreflightStep(id: "arch",
                                      title: "Architecture",
                                      state: isArm64 ? .pass : .fail,
                                      detail: "\(system.architecture) · \(system.deviceIdentifier)"))

        steps.append(JITPreflightStep(id: "devmode",
                                      title: "Developer Mode",
                                      state: system.developerMode == .inferredEnabled ? .pass : .warn,
                                      detail: system.developerMode.detail))

        steps.append(JITPreflightStep(id: "entitlement",
                                      title: "get-task-allow",
                                      state: system.hasGetTaskAllow ? .pass : .fail,
                                      detail: system.hasGetTaskAllow
                                        ? "The running app carries get-task-allow."
                                        : "Reinstall Vortex with a signing method that preserves get-task-allow."))

        steps.append(JITPreflightStep(id: "jit",
                                      title: "JIT available",
                                      state: system.isJITActive ? .pass : .warn,
                                      detail: system.isJITActive
                                        ? "Executable memory permitted and process debuggable."
                                        : "Not active yet: \(system.jitMemory.label)."))

        let pairingState: JITStepState
        switch pairing {
        case .present: pairingState = .pass
        case .missing: pairingState = .fail
        case .invalid: pairingState = .fail
        }
        steps.append(JITPreflightStep(id: "pairing",
                                      title: "Pairing file",
                                      state: pairingState,
                                      detail: pairing.detail))

        steps.append(JITPreflightStep(id: "ddi",
                                      title: "Developer Disk Image",
                                      state: .warn,
                                      detail: "Managed by StikJIT inside its helper extension. This build does not embed StikJIT, so no DDI is prepared here."))

        steps.append(JITPreflightStep(id: "vpn",
                                      title: "LocalDevVPN",
                                      state: vpn.isVerifiedConnected ? .pass : .warn,
                                      detail: vpn.detail))

        return steps
    }

    var blockingIssue: String? {
        if !system.supportsStikJIT {
            return "StikJIT requires iOS 17.4 or later."
        }
        if !system.hasGetTaskAllow {
            return "This installation does not have get-task-allow. Reinstall Vortex using a signing method that preserves it, then try again."
        }
        if method.requiresPairingFile && !pairing.isUsable {
            return "Import a valid pairing file before enabling JIT. \(pairing.detail)"
        }
        if let reason = method.availability.reason {
            return reason
        }
        return nil
    }

    // MARK: - Pairing

    @discardableResult
    func importPairing(from url: URL) -> String? {
        do {
            pairing = try store.importPairing(from: url)
            preflight = makePreflight()
            return nil
        } catch {
            pairing = store.status()
            preflight = makePreflight()
            return (error as? LocalizedError)?.errorDescription ?? "The pairing file could not be imported."
        }
    }

    func deletePairing() {
        store.deletePairing()
        pairing = store.status()
        preflight = makePreflight()
    }

    // MARK: - Activation

    func setUpJIT() {
        refresh()
        if let issue = blockingIssue {
            activation = .failed(issue)
            record(issue)
        } else {
            activation = .idle
        }
    }

    func enableJIT() {
        cancelPolling()
        refresh()

        if system.isJITActive {
            verifyAttachedState()
            return
        }

        if let issue = blockingIssue {
            fail(issue)
            return
        }

        switch method {
        case .builtInStikJIT:
            fail(method.availability.reason ?? "Built-in StikJIT is unavailable.")
        case .waitForDebugger:
            activation = .running("Waiting for a debugger to attach to this process…")
            startPolling()
        case .stikDebug:
            guard StikDebugLaunch.isInstalled else {
                fail("StikDebug is not installed. Install it, or switch to Wait for Debugger and attach Xcode.")
                return
            }
            guard let bundleID = Bundle.main.bundleIdentifier,
                  let url = StikDebugLaunch.enableJITURL(bundleIdentifier: bundleID,
                                                         processID: getpid(),
                                                         scriptName: system.txm == .present ? StikDebugLaunch.scriptName : nil) else {
                fail("The StikDebug request could not be built.")
                return
            }
            activation = .running("Opening StikDebug to enable JIT for this process…")
            UIApplication.shared.open(url)
            startPolling()
        }
    }

    func retry() {
        enableJIT()
    }

    func continueWithoutJIT() {
        cancelPolling()
        usesInterpreterOnly = true
        activation = .idle
        record("JIT skipped by the user; interpreter selected.")
    }

    func resumeJIT() {
        usesInterpreterOnly = false
        refresh()
    }

    func resetDeveloperDiskImage() {
        let message = "Developer Disk Image management lives in StikJIT's helper extension, which this build does not embed. Reset the cache from StikJIT, or follow SETUP.md to embed it."
        activation = .failed(message)
        record(message)
    }

    // MARK: - Attach polling

    private func startPolling(timeout: TimeInterval = 60) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(timeout)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                if JITHostProbe.isDebugged {
                    self.system = JITSystemInfo.current()
                    self.verifyAttachedState()
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            if case .running = self.activation {
                self.fail("No debugger attached within \(Int(timeout)) seconds. Check that StikDebug or Xcode is running and that the pairing file is current.")
            }
        }
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func verifyAttachedState() {
        system = JITSystemInfo.current()

        guard system.jitMemory == .available else {
            fail("A debugger is attached but executable memory is still denied. The pairing file may be invalidated — pair the device again.")
            return
        }

        guard system.canVerifyExecutionInProcess else {
            let message = "Debugger attached and executable memory permitted. iOS \(system.osMajor) requires each executable region to be prepared by the JIT script; this build does not embed StikJIT, so execution was not verified."
            activation = .unverified(message)
            record(message)
            return
        }

        let outcome = JITHostProbe.selfTest(executeCode: true)
        if outcome.executed {
            let message = "JIT verified on this device: AArch64 code written into JIT memory returned \(outcome.value)."
            activation = .succeeded(message)
            record(message)
        } else if outcome.allocated {
            fail("JIT memory was allocated but the self-test did not return the expected value.")
        } else {
            fail("Executable JIT memory could not be created for the self-test.")
        }
    }

    private func fail(_ message: String) {
        cancelPolling()
        activation = .failed(message)
        record(message)
    }

    private func record(_ message: String) {
        lastActivationSummary = message
        UserDefaults.standard.set(message, forKey: Self.lastResultDefaultsKey)
        preflight = makePreflight()
    }
}
