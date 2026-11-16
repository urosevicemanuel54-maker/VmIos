//
//  FramePacing.swift
//  Vortex
//
//  Frame-limit targets, the presentation gate and frame-interval measurement.
//  Everything here is pure arithmetic so it can be tested without a display.
//

import Foundation
import QuartzCore

/// Frame limit choices offered by the display bar.
enum FrameLimitTarget: Int, CaseIterable, Identifiable {
    case fps30
    case fps60
    case fps120
    case displayMax

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fps30: return "30"
        case .fps60: return "60"
        case .fps120: return "120"
        case .displayMax: return "Max"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .fps30: return "30 frames per second"
        case .fps60: return "60 frames per second"
        case .fps120: return "120 frames per second"
        case .displayMax: return "Display maximum"
        }
    }

    /// The measurable rate requested by this target, or nil when the display
    /// is allowed to run as fast as it can.
    var framesPerSecond: Double? {
        switch self {
        case .fps30: return 30
        case .fps60: return 60
        case .fps120: return 120
        case .displayMax: return nil
        }
    }

    /// Minimum spacing between presented frames. Zero means "no gate".
    func targetInterval(refreshRate: Double) -> Double {
        guard let fps = framesPerSecond, fps > 0 else { return 0 }
        return 1.0 / fps
    }

    /// The frame-time budget shown in the dashboard, in milliseconds.
    func budgetMs(refreshRate: Double) -> Double {
        if let fps = framesPerSecond { return 1000.0 / fps }
        return 1000.0 / max(1.0, refreshRate)
    }

    /// Range handed to CADisplayLink so the system paces the display to us.
    func preferredRange(maxRefreshRate: Float) -> CAFrameRateRange {
        let ceiling = max(30, maxRefreshRate)
        if let fps = framesPerSecond {
            let rate = min(Float(fps), ceiling)
            return CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        }
        return CAFrameRateRange(minimum: 0, maximum: ceiling, preferred: ceiling)
    }
}

/// Rejects display-link callbacks that arrive faster than the chosen target.
///
/// The display link cannot always be told to fire at exactly the rate we want
/// (a 60 Hz request on a 120 Hz panel still delivers 120 callbacks on some
/// configurations), so the gate is what actually enforces the limit.
struct FrameLimiter {
    /// Spacing between accepted frames in seconds. Zero disables the gate.
    var targetInterval: Double
    private(set) var lastAcceptedTime: Double?
    private(set) var skippedFrames: UInt64 = 0

    init(targetInterval: Double = 0) {
        self.targetInterval = max(0, targetInterval)
    }

    mutating func reset() {
        lastAcceptedTime = nil
        skippedFrames = 0
    }

    /// Returns true when a frame may be rendered at `time` (seconds).
    mutating func shouldRender(at time: Double) -> Bool {
        guard targetInterval > 0 else { return true }
        guard let last = lastAcceptedTime else {
            lastAcceptedTime = time
            return true
        }

        let elapsed = time - last
        let tolerance = targetInterval * 0.05
        if elapsed + tolerance < targetInterval {
            skippedFrames += 1
            return false
        }

        var next = last + targetInterval
        if time - next > targetInterval {
            next = time
        }
        lastAcceptedTime = next
        return true
    }
}

/// Rolling measurement of presented-frame intervals.
struct FrameIntervalSampler {
    private(set) var intervals: [Double] = []
    private var timestamps: [Double] = []
    private let intervalCapacity: Int
    private let window: Double

    init(intervalCapacity: Int = 90, window: Double = 1.0) {
        self.intervalCapacity = max(2, intervalCapacity)
        self.window = max(0.25, window)
    }

    mutating func record(timestamp: Double) {
        if let previous = timestamps.last {
            let delta = timestamp - previous
            if delta > 0 {
                intervals.append(delta)
                if intervals.count > intervalCapacity {
                    intervals.removeFirst(intervals.count - intervalCapacity)
                }
            }
        }

        timestamps.append(timestamp)
        let cutoff = timestamp - window
        while timestamps.count > 2, let first = timestamps.first, first < cutoff {
            timestamps.removeFirst()
        }
    }

    /// Frames per second over the sampling window, measured from timestamps.
    var measuredFramesPerSecond: Double {
        guard timestamps.count >= 2,
              let first = timestamps.first,
              let last = timestamps.last,
              last > first else {
            return 0
        }
        return Double(timestamps.count - 1) / (last - first)
    }

    var averageFrameTimeMs: Double {
        guard !intervals.isEmpty else { return 0 }
        let total = intervals.reduce(0, +)
        return (total / Double(intervals.count)) * 1000.0
    }

    /// Interval history in milliseconds, newest last, for the sparkline.
    var recentIntervalsMs: [Double] {
        intervals.map { $0 * 1000.0 }
    }
}
