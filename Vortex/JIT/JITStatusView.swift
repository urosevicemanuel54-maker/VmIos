//
//  JITStatusView.swift
//  Vortex
//
//  JIT status, setup checks and activation. Native iOS 26 controls, one accent.
//

import SwiftUI
import UniformTypeIdentifiers

struct JITStatusView: View {
    @ObservedObject var coordinator: JITCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingPairingGuide = false
    @State private var isShowingImportPicker = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overallCard
                    methodCard

                    if let summary = coordinator.lastActivationSummary {
                        card("Last activation") {
                            Text(summary)
                                .font(.system(size: 13))
                                .foregroundStyle(VortexPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    card("Checks") {
                        VStack(spacing: 0) {
                            ForEach(Array(coordinator.preflight.enumerated()), id: \.element.id) { index, step in
                                checkRow(step)
                                if index < coordinator.preflight.count - 1 {
                                    Divider().overlay(Color.white.opacity(0.06))
                                }
                            }
                        }
                    }

                    card("Actions") {
                        actionButtons
                    }

                    card("Requirements") {
                        VStack(alignment: .leading, spacing: 8) {
                            note("Vortex must be installed with get-task-allow. A build signed for the App Store does not have it.")
                            note("Developer Mode must be enabled in Settings › Privacy & Security › Developer Mode.")
                            note("StikDebug needs a current pairing file. Changing the passcode invalidates it.")
                            note("LocalDevVPN must be connected. Vortex verifies the tunnel endpoint before reporting it as connected.")
                            note("On iOS 26 and later each executable region must be prepared by the JIT script; this build reports that state as unverified rather than claiming success.")
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .background(VortexPalette.background.ignoresSafeArea())
            .navigationTitle("JIT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { coordinator.refresh() }
            .sheet(isPresented: $isShowingPairingGuide) {
                PairingGuideSheet(coordinator: coordinator,
                                  isShowingImportPicker: $isShowingImportPicker)
            }
            .fileImporter(isPresented: $isShowingImportPicker,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("Pairing file",
                   isPresented: Binding(get: { importError != nil },
                                        set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Cards

    private var overallCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: headlineIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(headlineTint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(headlineTint.opacity(0.14)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.overallHeadline)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(VortexPalette.primaryText)
                    Text("Execution: \(coordinator.executionMode.label)")
                        .font(.system(size: 12))
                        .foregroundStyle(VortexPalette.secondaryText)
                }

                Spacer()
            }

            if case .running(let step) = coordinator.activation {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(step)
                        .font(.system(size: 12))
                        .foregroundStyle(VortexPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(coordinator.overallDetail)
                .font(.system(size: 13))
                .foregroundStyle(VortexPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(coordinator.executionMode.detail)
                .font(.system(size: 12))
                .foregroundStyle(VortexPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(VortexPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(VortexPalette.stroke, lineWidth: 1))
    }

    private var methodCard: some View {
        card("Method") {
            VStack(alignment: .leading, spacing: 10) {
                Menu {
                    ForEach(JITMethod.allCases) { method in
                        Button {
                            coordinator.method = method
                        } label: {
                            if method.id == coordinator.method.id {
                                Label(method.title, systemImage: "checkmark")
                            } else {
                                Text(method.title)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(coordinator.method.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(VortexPalette.primaryText)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VortexPalette.tertiaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(VortexPalette.surfaceRaised))
                }

                if let reason = coordinator.method.availability.reason {
                    note(reason)
                } else if coordinator.method == .waitForDebugger {
                    note("Attach a debugger from Xcode or another tool; Vortex polls for CS_DEBUGGED and verifies JIT when the system allows it.")
                } else {
                    note("StikDebug is opened with this app's bundle identifier and PID, and with the universal script only when TXM is present.")
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                coordinator.setUpJIT()
                if !coordinator.pairing.isUsable {
                    isShowingPairingGuide = true
                }
            } label: {
                Label("Set Up JIT", systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                isShowingPairingGuide = true
            } label: {
                Label("Pair This Device", systemImage: "iphone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                coordinator.enableJIT()
            } label: {
                Label("Enable JIT", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 10) {
                Button {
                    coordinator.retry()
                } label: {
                    Text("Retry").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    coordinator.continueWithoutJIT()
                    dismiss()
                } label: {
                    Text("Continue Without JIT").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Button {
                    isShowingImportPicker = true
                } label: {
                    Text("Import Pairing File").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    coordinator.resetDeveloperDiskImage()
                } label: {
                    Text("Reset DDI").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Rows

    private func checkRow(_ step: JITPreflightStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint(for: step.state))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(step.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(VortexPalette.primaryText)
                    Spacer(minLength: 8)
                    Text(stateLabel(for: step.state))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint(for: step.state))
                }
                Text(step.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(VortexPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
    }

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

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(VortexPalette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tint(for state: JITStepState) -> Color {
        switch state {
        case .pass: return VortexPalette.positive
        case .warn: return VortexPalette.warning
        case .fail: return VortexPalette.critical
        case .info: return VortexPalette.secondaryText
        }
    }

    private func stateLabel(for state: JITStepState) -> String {
        switch state {
        case .pass: return "OK"
        case .warn: return "CHECK"
        case .fail: return "BLOCKED"
        case .info: return "INFO"
        }
    }

    private var headlineIcon: String {
        if case .failed = coordinator.activation { return "exclamationmark.triangle.fill" }
        if coordinator.system.isJITActive { return "bolt.fill" }
        return "bolt.slash"
    }

    private var headlineTint: Color {
        if case .failed = coordinator.activation { return VortexPalette.critical }
        if coordinator.system.isJITActive { return VortexPalette.positive }
        return VortexPalette.warning
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if let message = coordinator.importPairing(from: url) {
                importError = message
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

// MARK: - Pairing guide

struct PairingGuideSheet: View {
    @ObservedObject var coordinator: JITCoordinator
    @Binding var isShowingImportPicker: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("How pairing works") {
                        Text("A pairing record is a device-specific property list that lets a local debugger talk to this iPhone. Vortex cannot create one itself: Apple's pairing exchange runs on a host process, which is why StikJIT keeps pairing outside its library and StikDebug performs it.")
                            .font(.system(size: 13))
                            .foregroundStyle(VortexPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section("On-device (iOS 27 or later)") {
                        numbered(1, "Install StikDebug from its AltSource or release .ipa.")
                        numbered(2, "In StikDebug open Settings › Pair a Device › Pair iPhone or iPad and follow the instructions.")
                        numbered(3, "Export the file, or place it for Vortex: StikDebug saves its own record; share it with the Files app.")
                        numbered(4, "Return here and tap Import Pairing File.")
                    }

                    section("With a computer (any supported iOS)") {
                        numbered(1, "Install iloader on macOS, Windows or Linux and connect the device.")
                        numbered(2, "Choose Manage Pairing File and place it for Vortex, or copy it to this app's Documents/StikJIT folder using Finder file sharing.")
                        numbered(3, "If you copied it yourself it is already in place; otherwise import it here.")
                    }

                    section("Stored location") {
                        Text("Vortex stores exactly one record at Documents/StikJIT/pairingFile.plist, with complete file protection and excluded from backup. Vortex never logs it, never sends it anywhere and never shows its contents. Changing or resetting the device passcode invalidates it; pair again when activation starts failing.")
                            .font(.system(size: 13))
                            .foregroundStyle(VortexPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section("Current file") {
                        Text(coordinator.pairing.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(VortexPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        isShowingImportPicker = true
                    } label: {
                        Label("Import Pairing File", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if coordinator.pairing.isUsable {
                        Button(role: .destructive) {
                            coordinator.deletePairing()
                        } label: {
                            Text("Remove Pairing File").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .background(VortexPalette.background.ignoresSafeArea())
            .navigationTitle("Pair This Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(VortexPalette.tertiaryText)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(VortexPalette.surface))
    }

    private func numbered(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VortexPalette.primaryText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(VortexPalette.surfaceRaised))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(VortexPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
