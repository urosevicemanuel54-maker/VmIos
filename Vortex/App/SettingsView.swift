//
//  SettingsView.swift
//  Vortex
//
//  Core state, pacing configuration and the platform restrictions that shape
//  this emulator's design.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: EmulatorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Native core") {
                    infoRow("Build", VortexCoreHandle.buildLabel)
                    infoRow("C ABI", "v\(VortexCoreHandle.abiVersion)")
                    infoRow("Guest CPU", "ARM64 interpreter — \(CPUInspectorModel.formatRate(model.core.cpu.snapshot.instructionsPerSecond))")
                    infoRow("Guest raster", "\(model.snapshot.guestWidth) x \(model.snapshot.guestHeight)")
                    infoRow("Guest clock", "60 Hz fixed step")
                    infoRow("Guest memory", CPUInspectorModel.formatBytes(model.core.cpu.memorySize()))
                }

                Section("Frame pacing") {
                    infoRow("Display refresh", "\(Int(model.snapshot.displayRefreshRate.rounded())) Hz")
                    infoRow("Target", model.frameLimit.accessibilityTitle)
                    infoRow("Frame budget", "\(MetricsFormatting.milliseconds(model.snapshot.budgetMs)) ms")
                    infoRow("Render scale", MetricsFormatting.scale(model.snapshot.renderScale))
                    infoRow("GPU frame time", model.snapshot.gpuTimeMs.map { "\(MetricsFormatting.milliseconds($0)) ms" } ?? "not reported")
                }

                Section("Measured counters") {
                    infoRow("Frames presented", MetricsFormatting.counter(model.snapshot.framesPresented))
                    infoRow("Frames skipped", MetricsFormatting.counter(model.snapshot.framesSkipped))
                    infoRow("Guest ticks", MetricsFormatting.counter(model.snapshot.guestTicks))
                    infoRow("Instructions", MetricsFormatting.counter(model.snapshot.instructionsExecuted))
                    infoRow("Emulation errors", MetricsFormatting.counter(model.snapshot.emulationErrors))
                    infoRow("Memory footprint", MetricsFormatting.megabytes(model.snapshot.memoryFootprintBytes))
                }

                Section("JIT") {
                    infoRow("Status", model.jit.overallHeadline)
                    infoRow("Method", model.jit.method.title)
                    infoRow("Pairing file", model.jit.pairing.label)
                    infoRow("Execution", model.jit.executionMode.label)
                    policyNote(model.jit.executionMode.detail)
                    policyNote("Activation always runs through the selected method only. Vortex falls back to its interpreter when JIT is not confirmed.")
                }

                Section("Platform limits") {
                    noteText("Guest code runs only in a software interpreter compiled into the app. iOS does not let an ordinary app allocate executable memory, so JIT compilation and dynamic recompilation are unavailable unless the JIT activation above succeeds.")
                    noteText("There is no access to hardware virtualisation or hypervisor APIs from a third-party iOS app, so the guest cannot share the A15's execution units.")
                    noteText("Rendering is host Metal only: the guest framebuffer is a texture this app rasterises and composites. There is no guest GPU passthrough.")
                    noteText("Metal does not expose a GPU utilisation percentage. The GPU tile reports measured command-buffer GPU time instead, and shows n/a until the driver reports it.")
                    noteText("Every dashboard value is measured at runtime. Instructions executed comes from the guest CPU's counter; emulation errors come from the interpreter's typed error log.")
                }

                Section("About") {
                    noteText("Vortex is an experimental emulation platform. Its system environment is an original interface, not Apple's operating system, and it does not execute Apple software.")
                    infoRow("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                model.jit.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 14))
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func policyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
