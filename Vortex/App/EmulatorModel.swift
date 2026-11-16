//
//  EmulatorModel.swift
//  Vortex
//
//  Owns the core handle, the frame loop and the measured dashboard state.
//  Everything runs on the main thread.
//

import Foundation
import QuartzCore

final class EmulatorModel: ObservableObject {
    @Published private(set) var snapshot: PerformanceSnapshot = .placeholder
    @Published private(set) var failureMessage: String?
    @Published private(set) var isPaused: Bool = false
    @Published var isFullScreenPresented: Bool = false

    @Published var frameLimit: FrameLimitTarget = .fps120 {
        didSet {
            loop.limit = frameLimit
            fullScreenLoop?.limit = frameLimit
            publishSnapshot()
        }
    }

    @Published var isShowingJITStatus = false

    let core: VortexCoreHandle
    let loop: FrameLoop
    let jit: JITCoordinator

    private var fullScreenLoop: FrameLoop?
    private var latestReport: FrameLoop.FrameReport?
    private var lastSnapshotTime: Double = 0

    init() {
        let core = VortexCoreHandle()
        let loop = FrameLoop(core: core)

        self.core = core
        self.loop = loop
        self.jit = JITCoordinator()

        loop.limit = .fps120
        loop.onReport = { [weak self] report in
            self?.receive(report)
        }
        loop.onFailure = { [weak self] message in
            self?.failureMessage = message
        }

        publishSnapshot()
    }

    // MARK: - Reporting

    private func receive(_ report: FrameLoop.FrameReport) {
        latestReport = report

        let now = CACurrentMediaTime()
        guard now - lastSnapshotTime >= 0.1 else { return }
        lastSnapshotTime = now
        publishSnapshot()
    }

    func publishSnapshot() {
        let stats = core.stats
        let processInfo = ProcessInfo.processInfo
        let refreshRate = latestReport?.displayRefreshRate ?? snapshot.displayRefreshRate

        snapshot = PerformanceSnapshot(measuredFPS: isPaused ? 0 : (latestReport?.measuredFPS ?? 0),
                                       frameTimeMs: latestReport?.frameTimeMs ?? 0,
                                       frameTimeSamples: latestReport?.frameTimeSamples ?? [],
                                       gpuTimeMs: latestReport?.gpuTimeMs,
                                       budgetMs: frameLimit.budgetMs(refreshRate: refreshRate),
                                       memoryFootprintBytes: MemoryProbe.footprintBytes(),
                                       thermal: ThermalLevel(thermalState: processInfo.thermalState),
                                       isLowPowerMode: processInfo.isLowPowerModeEnabled,
                                       framesPresented: stats.framesPresented,
                                       framesSkipped: stats.framesSkipped,
                                       instructionsExecuted: stats.instructionsExecuted,
                                       emulationErrors: stats.emulationErrors,
                                       guestTicks: stats.guestTicks,
                                       guestWidth: stats.guestWidth,
                                       guestHeight: stats.guestHeight,
                                       renderScale: latestReport?.renderScale ?? snapshot.renderScale,
                                       displayRefreshRate: refreshRate)
    }

    // MARK: - Controls

    func togglePause() {
        isPaused.toggle()
        loop.isPaused = isPaused
        publishSnapshot()
    }

    func resetMetrics() {
        loop.resetMetrics()
        latestReport = nil
        publishSnapshot()
    }

    // MARK: - Full screen session

    func beginFullScreenSession(with fullScreenLoop: FrameLoop) {
        self.fullScreenLoop = fullScreenLoop
        fullScreenLoop.limit = frameLimit
        fullScreenLoop.onReport = { [weak self] report in
            self?.receive(report)
        }
        loop.isPaused = true
    }

    func endFullScreenSession() {
        fullScreenLoop?.detach()
        fullScreenLoop = nil
        loop.isPaused = isPaused
        publishSnapshot()
    }
}
