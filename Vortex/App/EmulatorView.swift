//
//  EmulatorView.swift
//  Vortex
//
//  The emulator display screen: Metal virtual display plus the live,
//  measured performance dashboard.
//

import SwiftUI

struct EmulatorView: View {
    @StateObject private var model = EmulatorModel()
    @State private var activeSheet: EmulatorSheet?

    private enum EmulatorSheet: String, Identifiable {
        case settings
        case jit
        case cpu

        var id: String { rawValue }
    }

    private var guestAspectRatio: CGFloat {
        CGFloat(model.snapshot.guestWidth) / CGFloat(max(1, model.snapshot.guestHeight))
    }

    private var isCoreAvailable: Bool { model.failureMessage == nil }

    var body: some View {
        ZStack {
            VortexPalette.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    displayCard
                    metricsGrid
                    controlBar
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .preferredColorScheme(.dark)
        .tint(VortexPalette.accent)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView(model: model)
            case .jit:
                JITStatusView(coordinator: model.jit)
            case .cpu:
                CPUInspectorView(cpu: model.core.cpu)
            }
        }
        .fullScreenCover(isPresented: $model.isFullScreenPresented) {
            FullScreenDisplayView(model: model)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Vortex")
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(VortexPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            Button {
                activeSheet = .jit
            } label: {
                statusPill
            }
            .buttonStyle(.plain)
            .accessibilityLabel("JIT status")

            Button {
                activeSheet = .cpu
            } label: {
                Image(systemName: "cpu")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(VortexPalette.primaryText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(VortexPalette.surface))
                    .overlay(Circle().stroke(VortexPalette.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("CPU inspector")

            Button {
                activeSheet = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(VortexPalette.primaryText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(VortexPalette.surface))
                    .overlay(Circle().stroke(VortexPalette.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 4)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isCoreAvailable ? VortexPalette.positive : VortexPalette.warning)
                .frame(width: 9, height: 9)
                .shadow(color: (isCoreAvailable ? VortexPalette.positive : VortexPalette.warning).opacity(0.6),
                        radius: 5)
            Text(isCoreAvailable ? "Native core" : "Core offline")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(VortexPalette.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Capsule().fill(VortexPalette.surface))
        .overlay(Capsule().stroke(VortexPalette.stroke, lineWidth: 1))
    }

    // MARK: - Virtual display

    private var displayCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.black
                MetalDisplayView(loop: model.loop)
                if let failureMessage = model.failureMessage {
                    failureOverlay(failureMessage)
                }
            }
            .aspectRatio(guestAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("\(model.snapshot.guestWidth) x \(model.snapshot.guestHeight) · Native raster")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VortexPalette.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func failureOverlay(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(VortexPalette.warning)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(VortexPalette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Metrics

    private var metricsGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                fpsTile
                frameTimeTile
                scaleTile
            }
            HStack(spacing: 12) {
                memoryTile
                thermalTile
                gpuTile
            }
        }
    }

    private var fpsTile: some View {
        metricTile("FPS", height: 118) {
            VStack(alignment: .leading, spacing: 8) {
                valueText(MetricsFormatting.fps(model.snapshot.measuredFPS), size: 30)
                Sparkline(samples: model.snapshot.frameTimeSamples)
                    .frame(height: 30)
            }
        }
    }

    private var frameTimeTile: some View {
        metricTile("Frame time", height: 118) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    valueText(MetricsFormatting.milliseconds(model.snapshot.frameTimeMs), size: 26)
                    Text("ms")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(VortexPalette.primaryText)
                }
                Text("budget \(MetricsFormatting.milliseconds(model.snapshot.budgetMs)) ms")
                    .font(.system(size: 12))
                    .foregroundStyle(VortexPalette.tertiaryText)
                    .lineLimit(1)
            }
        }
    }

    private var scaleTile: some View {
        metricTile("Scale", height: 118) {
            valueText(MetricsFormatting.scale(model.snapshot.renderScale), size: 26)
        }
    }

    private var memoryTile: some View {
        metricTile("Memory", height: 96) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                valueText(MetricsFormatting.megabytesValue(model.snapshot.memoryFootprintBytes), size: 26)
                Text("MB")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(VortexPalette.primaryText)
            }
        }
    }

    private var thermalTile: some View {
        metricTile("Thermal", height: 96) {
            VStack(alignment: .leading, spacing: 2) {
                valueText(model.snapshot.thermal.label, size: 26)
                    .foregroundStyle(thermalColor)
                if model.snapshot.isLowPowerMode {
                    Text("Low power mode")
                        .font(.system(size: 11))
                        .foregroundStyle(VortexPalette.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private var gpuTile: some View {
        metricTile("GPU", height: 96) {
            if let gpuTime = model.snapshot.gpuTimeMs {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    valueText(MetricsFormatting.milliseconds(gpuTime), size: 26)
                    Text("ms")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(VortexPalette.primaryText)
                }
            } else {
                valueText("n/a", size: 26)
                    .foregroundStyle(VortexPalette.tertiaryText)
            }
        }
    }

    private var thermalColor: Color {
        switch model.snapshot.thermal {
        case .nominal: return VortexPalette.positive
        case .fair: return VortexPalette.warning
        case .serious: return VortexPalette.serious
        case .critical: return VortexPalette.critical
        }
    }

    private func metricTile<Content: View>(_ title: String,
                                           height: CGFloat,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(VortexPalette.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            content()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(VortexPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(VortexPalette.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func valueText(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(VortexPalette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Frame limit")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(VortexPalette.secondaryText)
                FrameLimitPicker(selection: $model.frameLimit)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 44)

            HStack(spacing: 9) {
                roundButton(systemName: model.isPaused ? "play.fill" : "pause.fill",
                            accessibilityLabel: model.isPaused ? "Resume" : "Pause",
                            action: model.togglePause)
                roundButton(systemName: "arrow.counterclockwise",
                            accessibilityLabel: "Reset counters",
                            action: { model.resetMetrics() })
                roundButton(systemName: "arrow.up.left.and.arrow.down.right",
                            accessibilityLabel: "Full screen display",
                            action: { model.isFullScreenPresented = true })
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(VortexPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(VortexPalette.stroke, lineWidth: 1))
    }

    private func roundButton(systemName: String,
                             accessibilityLabel: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VortexPalette.primaryText)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().stroke(VortexPalette.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 5) {
            Text(counterLine)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(VortexPalette.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("Measured on this device · counters not yet wired show 0")
                .font(.system(size: 12))
                .foregroundStyle(VortexPalette.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var counterLine: String {
        let snapshot = model.snapshot
        return "frames \(snapshot.framesPresented) · skipped \(snapshot.framesSkipped) · insns \(snapshot.instructionsExecuted) · errors \(snapshot.emulationErrors)"
    }
}

// MARK: - Frame limit picker

struct FrameLimitPicker: View {
    @Binding var selection: FrameLimitTarget

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FrameLimitTarget.allCases) { target in
                Button {
                    selection = target
                } label: {
                    Text(target.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selection == target ? VortexPalette.primaryText : VortexPalette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if selection == target {
                                Capsule(style: .continuous).fill(VortexPalette.accent)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(target.accessibilityTitle)
                .accessibilityAddTraits(selection == target ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geometry in
            let points = Sparkline.normalizedPoints(samples: samples, size: geometry.size)
            if points.count > 1 {
                ZStack {
                    fillPath(points: points, height: geometry.size.height)
                        .fill(LinearGradient(colors: [VortexPalette.accent.opacity(0.45),
                                                      VortexPalette.accent.opacity(0.02)],
                                             startPoint: .top,
                                             endPoint: .bottom))
                    linePath(points: points)
                        .stroke(VortexPalette.accent,
                                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    static func normalizedPoints(samples: [Double], size: CGSize) -> [CGPoint] {
        guard samples.count > 1, size.width > 1, size.height > 1 else { return [] }
        let values = Array(samples.suffix(60))
        guard values.count > 1 else { return [] }
        let peak = max(values.max() ?? 1, 0.001)
        let upper = peak * 1.25

        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let ratio = min(max(value / upper, 0), 1)
            let y = size.height * (1 - CGFloat(ratio))
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { path in
            path.addLines(points)
        }
    }

    private func fillPath(points: [CGPoint], height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: points[0].x, y: height))
            path.addLines(points)
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
            path.closeSubpath()
        }
    }
}

// MARK: - Full screen display

struct FullScreenDisplayView: View {
    @ObservedObject var model: EmulatorModel
    @Environment(\.dismiss) private var dismiss

    @State private var loop: FrameLoop

    init(model: EmulatorModel) {
        self.model = model
        _loop = State(initialValue: FrameLoop(core: model.core))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalDisplayView(loop: loop)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(VortexPalette.primaryText)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close full screen display")
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                Spacer()

                Text("\(MetricsFormatting.fps(model.snapshot.measuredFPS)) fps · \(model.snapshot.guestWidth) x \(model.snapshot.guestHeight)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.bottom, 16)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            model.beginFullScreenSession(with: loop)
        }
        .onDisappear {
            model.endFullScreenSession()
        }
    }
}

#Preview {
    EmulatorView()
}
