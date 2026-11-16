//
//  FrameLoop.swift
//  Vortex
//
//  The measured frame loop: a CADisplayLink driven by a fixed-step guest clock,
//  gated by the frame limit, measured per frame.
//
//  All members are touched on the main thread only.
//

import Foundation
import Metal
import QuartzCore
import UIKit

/// Thread-safe store of recent command-buffer GPU times.
final class GpuTimingAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var samples: [Double] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func record(_ seconds: Double) {
        lock.lock()
        samples.append(seconds)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        lock.unlock()
    }

    func averageSeconds() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}

final class FrameLoop: NSObject {
    struct FrameReport {
        let measuredFPS: Double
        let frameTimeMs: Double
        let frameTimeSamples: [Double]
        let gpuTimeMs: Double?
        let framesPresented: UInt64
        let framesSkipped: UInt64
        let instructionsExecuted: UInt64
        let emulationErrors: UInt64
        let guestTicks: UInt64
        let guestWidth: Int
        let guestHeight: Int
        let displayRefreshRate: Double
        let renderScale: Double
    }

    var onReport: ((FrameReport) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Frame limit applied by the gate and the display link.
    var limit: FrameLimitTarget = .fps120 {
        didSet { applyLimit() }
    }

    /// Pausing stops the link; resuming restarts measurement from a clean slate.
    var isPaused: Bool = false {
        didSet {
            displayLink?.isPaused = isPaused
            if !isPaused {
                sampler = FrameIntervalSampler()
                limiter.reset()
                lastRenderedTimestamp = nil
                lastReportTime = 0
            }
        }
    }

    private let core: VortexCoreHandle
    private weak var hostView: UIView?
    private weak var metalLayer: CAMetalLayer?
    private var renderer: MetalRenderer?
    private var displayLink: CADisplayLink?
    private var limiter = FrameLimiter()
    private var sampler = FrameIntervalSampler()
    private let gpuTiming = GpuTimingAccumulator(capacity: 30)
    private var lastRenderedTimestamp: Double?
    private var lastReportTime: Double = 0
    private var displayRefreshRate: Double = 60

    init(core: VortexCoreHandle) {
        self.core = core
        super.init()
    }

    // MARK: - Attachment

    func attach(layer: CAMetalLayer, in view: UIView) {
        if let current = metalLayer, current === layer, displayLink != nil {
            return
        }
        detach()

        hostView = view
        metalLayer = layer

        if let refreshRate = view.window?.windowScene?.screen.maximumFramesPerSecond {
            displayRefreshRate = Double(max(30, refreshRate))
        }

        if let existing = renderer {
            layer.device = existing.device
        } else {
            guard let device = MTLCreateSystemDefaultDevice() else {
                onFailure?("Metal is not available on this device.")
                return
            }
            layer.device = device
            do {
                renderer = try MetalRenderer(device: device)
            } catch {
                onFailure?(error.localizedDescription)
                return
            }
        }

        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = true
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3

        updateDrawableSize(view.bounds.size, scale: view.contentScaleFactor)

        let selector = #selector(step(_:))
        var link = CADisplayLink(target: self, selector: selector)
        if #available(iOS 27.0, *),
           let scene = view.window?.windowScene,
           let sceneLink = scene.displayLink(target: self, selector: selector) {
            link = sceneLink
        }
        link.add(to: .main, forMode: .common)
        displayLink = link

        applyLimit()
        link.isPaused = isPaused
    }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
        metalLayer = nil
        hostView = nil
        lastRenderedTimestamp = nil
    }

    /// Detaches only when the layer being torn down is the one in use.
    func detachIfCurrent(layer: CAMetalLayer) {
        guard let current = metalLayer, current === layer else { return }
        detach()
    }

    func updateDrawableSize(_ size: CGSize, scale: CGFloat) {
        guard let layer = metalLayer, size.width >= 1, size.height >= 1 else { return }
        let boundedScale = min(max(scale, 1), 3)
        layer.drawableSize = CGSize(width: (size.width * boundedScale).rounded(),
                                    height: (size.height * boundedScale).rounded())
    }

    // MARK: - Controls

    private func applyLimit() {
        guard let link = displayLink else { return }
        limiter.targetInterval = limit.targetInterval(refreshRate: displayRefreshRate)
        link.preferredFrameRateRange = limit.preferredRange(maxRefreshRate: Float(displayRefreshRate))
    }

    private func resetCounters() {
        core.reset()
        sampler = FrameIntervalSampler()
        limiter.reset()
        gpuTiming.reset()
        lastReportTime = 0
    }

    func resetMetrics() {
        resetCounters()
        publishReport(force: true)
    }

    // MARK: - Frame

    @objc private func step(_ link: CADisplayLink) {
        guard !isPaused, let renderer, let layer = metalLayer else { return }

        let gateTime = link.targetTimestamp
        guard limiter.shouldRender(at: gateTime) else {
            core.noteFrameSkipped()
            publishReport()
            return
        }

        if let previous = lastRenderedTimestamp, gateTime > previous {
            core.advance(delta: gateTime - previous)
        } else {
            core.advance(delta: 1.0 / Double(VORTEX_GUEST_TICK_HZ))
        }
        lastRenderedTimestamp = gateTime

        guard let drawable = layer.nextDrawable() else {
            core.noteFrameSkipped()
            publishReport()
            return
        }

        let drawableSize = layer.drawableSize
        guard let commandBuffer = renderer.encodeFrame(drawable: drawable,
                                                       drawableSize: drawableSize,
                                                       markerPosition: core.markerPosition) else {
            return
        }

        let timings = gpuTiming
        commandBuffer.addCompletedHandler { buffer in
            let interval = buffer.gpuEndTime - buffer.gpuStartTime
            if interval.isFinite, interval > 0, interval < 0.5 {
                timings.record(interval)
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        core.noteFramePresented()
        sampler.record(timestamp: gateTime)
        publishReport()
    }

    private func publishReport(force: Bool = false) {
        let now = CACurrentMediaTime()
        if !force, now - lastReportTime < 0.1 { return }
        lastReportTime = now

        let stats = core.stats
        let report = FrameReport(measuredFPS: sampler.measuredFramesPerSecond,
                                 frameTimeMs: sampler.averageFrameTimeMs,
                                 frameTimeSamples: sampler.recentIntervalsMs,
                                 gpuTimeMs: gpuTiming.averageSeconds().map { $0 * 1000.0 },
                                 framesPresented: stats.framesPresented,
                                 framesSkipped: stats.framesSkipped,
                                 instructionsExecuted: stats.instructionsExecuted,
                                 emulationErrors: stats.emulationErrors,
                                 guestTicks: stats.guestTicks,
                                 guestWidth: stats.guestWidth,
                                 guestHeight: stats.guestHeight,
                                 displayRefreshRate: displayRefreshRate,
                                 renderScale: renderer?.renderScale ?? 1.0)
        onReport?(report)
    }
}
