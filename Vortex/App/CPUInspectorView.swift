//
//  CPUInspectorView.swift
//  Vortex
//
//  Guest CPU inspector: execution control, register file, decode window,
//  breakpoints and the typed error log.
//

import SwiftUI

struct CPUInspectorView: View {
    @StateObject private var model: CPUInspectorModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsVectors = false

    init(cpu: GuestCPU) {
        _model = StateObject(wrappedValue: CPUInspectorModel(cpu: cpu))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    executionCard
                    stateCard
                    if let error = model.lastError {
                        errorCard(error)
                    }
                    disassemblyCard
                    registersCard
                    vectorsCard
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .background(VortexPalette.background.ignoresSafeArea())
            .navigationTitle("CPU")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.stop()
                        dismiss()
                    }
                }
            }
            .task {
                if model.snapshot.instructionsExecuted == 0,
                   model.disassembly.allSatisfy({ $0.instruction == 0 }) {
                    model.loadDemoProgram()
                } else {
                    model.refresh()
                }
            }
            .onDisappear { model.stop() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Execution

    private var executionCard: some View {
        card("Execution") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        model.step()
                    } label: {
                        Label("Step", systemImage: "stepforward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.toggleRunning()
                    } label: {
                        Label(model.isRunning ? "Stop" : "Run",
                              systemImage: model.isRunning ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.reset()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Button {
                        model.loadDemoProgram()
                    } label: {
                        Text("Load demo program").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.clearBreakpoints()
                    } label: {
                        Text("Clear breakpoints").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Divider().overlay(Color.white.opacity(0.06))

                metricRow("Instructions per second",
                          CPUInspectorModel.formatRate(model.snapshot.instructionsPerSecond))
                metricRow("Executed", "\(model.snapshot.instructionsExecuted)")
                metricRow("Decode cache",
                          "\(Int((model.snapshot.decodeHitRate * 100).rounded()))% hit · \(model.snapshot.decodeMisses) decodes")
                metricRow("Guest memory", model.memorySizeText)
            }
        }
    }

    private var stateCard: some View {
        card("State") {
            VStack(alignment: .leading, spacing: 10) {
                metricRow("PC", CPUInspectorModel.hex(model.snapshot.pc))
                metricRow("SP", CPUInspectorModel.hex(model.snapshot.sp))

                HStack(spacing: 8) {
                    flagChip("N", active: model.snapshot.flagN)
                    flagChip("Z", active: model.snapshot.flagZ)
                    flagChip("C", active: model.snapshot.flagC)
                    flagChip("V", active: model.snapshot.flagV)
                    Spacer()
                    Text(model.snapshot.halted ? "Halted" : (model.isRunning ? "Running" : "Paused"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.snapshot.halted ? VortexPalette.critical : VortexPalette.secondaryText)
                }
            }
        }
    }

    private func errorCard(_ error: GuestCPU.ErrorReport) -> some View {
        card("Error log") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(error.kind.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VortexPalette.critical)
                    Spacer()
                    Button("Clear") { model.clearError() }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(VortexPalette.accent)
                }
                Text(error.message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(VortexPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("PC \(CPUInspectorModel.hex(error.pc)) · word 0x\(String(format: "%08x", error.instruction))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VortexPalette.tertiaryText)
            }
        }
    }

    // MARK: - Disassembly

    private var disassemblyCard: some View {
        card("Decode window") {
            VStack(spacing: 0) {
                ForEach(Array(model.disassembly.enumerated()), id: \.element.id) { _, line in
                    Button {
                        model.toggleBreakpoint(at: line.pc)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(line.hasBreakpoint ? VortexPalette.critical : Color.clear)
                                .frame(width: 6, height: 6)
                            Text(CPUInspectorModel.shortHex(line.pc))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(VortexPalette.tertiaryText)
                                .frame(width: 58, alignment: .leading)
                            Text(line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(VortexPalette.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(String(format: "%08x", line.instruction))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(VortexPalette.tertiaryText.opacity(0.7))
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background {
                            if line.pc == model.snapshot.pc {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(VortexPalette.accent.opacity(0.18))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(line.text), \(line.hasBreakpoint ? "remove breakpoint" : "set breakpoint")")
                }
            }
        }
    }

    // MARK: - Registers

    private var registersCard: some View {
        card("Registers") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 6) {
                    ForEach(0..<31, id: \.self) { index in
                        HStack(spacing: 6) {
                            Text("x\(index)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(VortexPalette.tertiaryText)
                                .frame(width: 26, alignment: .leading)
                            Text(CPUInspectorModel.hex(model.registers[index]))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(VortexPalette.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                        }
                    }
                }
                Divider().overlay(Color.white.opacity(0.06))
                HStack(spacing: 6) {
                    Text("sp")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(VortexPalette.tertiaryText)
                        .frame(width: 26, alignment: .leading)
                    Text(CPUInspectorModel.hex(model.snapshot.sp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(VortexPalette.primaryText)
                }
            }
        }
    }

    private var vectorsCard: some View {
        card("Vector registers") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsVectors.toggle() }
                } label: {
                    HStack {
                        Text(showsVectors ? "Hide V0–V31" : "Show V0–V31")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(VortexPalette.accent)
                        Spacer()
                        Image(systemName: showsVectors ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(VortexPalette.tertiaryText)
                    }
                }
                .buttonStyle(.plain)

                if showsVectors {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)],
                              spacing: 6) {
                        ForEach(model.vectors) { vector in
                            HStack(spacing: 6) {
                                Text("v\(vector.index)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(VortexPalette.tertiaryText)
                                    .frame(width: 26, alignment: .leading)
                                Text(String(format: "%016llx", vector.low))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(VortexPalette.primaryText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                } else {
                    Text("128-bit lanes, low half shown when expanded.")
                        .font(.system(size: 11))
                        .foregroundStyle(VortexPalette.tertiaryText)
                }
            }
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(VortexPalette.tertiaryText)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(VortexPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(VortexPalette.stroke, lineWidth: 1))
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(VortexPalette.secondaryText)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(VortexPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func flagChip(_ letter: String, active: Bool) -> some View {
        Text(letter)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(active ? VortexPalette.background : VortexPalette.tertiaryText)
            .frame(width: 24, height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? VortexPalette.positive : Color.white.opacity(0.06)))
    }
}
