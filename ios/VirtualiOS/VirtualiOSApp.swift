import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

@main
struct VirtualiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = VirtualMachineController()
    @State private var importingFile = false
    @State private var importTarget: ImportTarget?
    @State private var showingError = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("VirtualiOS")
                                .font(.title2.bold())
                            Text("ARM64 · QEMU TCI")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Label(vm.status.title, systemImage: vm.status.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(vm.status.color)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Guest display")
                                .font(.headline)
                            Spacer()
                            Button {
                                vm.captureFramebuffer(reportErrors: true)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!vm.isRunning)
                            .accessibilityLabel("Refresh guest display")
                        }

                        Group {
                            if let image = vm.framebuffer {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "display")
                                        .font(.system(size: 30))
                                    Text(vm.isRunning ? "Waiting for guest framebuffer" : "Guest display is stopped")
                                        .font(.caption)
                                }
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(maxWidth: .infinity, minHeight: 190)
                            }
                        }
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .background(Color.black)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Machine")
                            .font(.headline)

                        HStack {
                            Label("Memory", systemImage: "memorychip")
                            Spacer()
                            Stepper("\(vm.memoryMB) MB", value: $vm.memoryMB, in: 256...4096, step: 256)
                                .fixedSize()
                                .disabled(vm.isRunning || vm.isStarting)
                        }

                        HStack {
                            Label("CPU cores", systemImage: "cpu")
                            Spacer()
                            Stepper("\(vm.cpuCount)", value: $vm.cpuCount, in: 1...4)
                                .fixedSize()
                                .disabled(vm.isRunning || vm.isStarting)
                        }

                        fileRow(title: "Linux kernel", filename: vm.kernelURL?.lastPathComponent, icon: "doc.zipper") {
                            selectFile(.kernel)
                        }

                        fileRow(title: "Raw disk image", filename: vm.diskURL?.lastPathComponent, icon: "internaldrive") {
                            selectFile(.disk)
                        }

                        HStack {
                            Label("New disk", systemImage: "externaldrive.badge.plus")
                            Spacer()
                            Stepper("\(vm.diskSizeGB) GB", value: $vm.diskSizeGB, in: 1...32)
                                .fixedSize()
                                .disabled(vm.isRunning || vm.isStarting)
                            Button {
                                vm.createDisk()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(vm.isRunning || vm.isStarting)
                            .accessibilityLabel("Create raw virtual disk")
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            do {
                                try vm.start()
                            } catch {
                                vm.errorMessage = error.localizedDescription
                                showingError = true
                            }
                        } label: {
                            Label("Start", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isRunning || vm.isStarting || vm.kernelURL == nil)

                        Button {
                            vm.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!vm.isRunning)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Debug console")
                                .font(.headline)
                            Spacer()
                            Button {
                                vm.clearConsole()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Clear console")
                        }

                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(vm.consoleText.isEmpty ? "QEMU output will appear here." : vm.consoleText)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.green.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id("console-bottom")
                            }
                            .frame(height: 150)
                            .padding(12)
                            .background(Color.black)
                            .onChange(of: vm.consoleText) { _ in
                                proxy.scrollTo("console-bottom", anchor: .bottom)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .tint(.teal)
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            guard let target = importTarget else { return }
            vm.importFile(result, target: target)
            importTarget = nil
        }
        .alert("Virtual machine", isPresented: $showingError) {
            Button("OK", role: .cancel) {
                vm.errorMessage = nil
            }
        } message: {
            Text(vm.errorMessage ?? "An unexpected error occurred.")
        }
        .onChange(of: vm.errorMessage) { message in
            showingError = message != nil
        }
    }

    private func fileRow(title: String, filename: String?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Text(filename ?? "Choose file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "folder")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(vm.isRunning)
    }

    private func selectFile(_ target: ImportTarget) {
        importTarget = target
        importingFile = true
    }
}

private enum ImportTarget: Equatable {
    case kernel
    case disk
}

@MainActor
private final class VirtualMachineController: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case stopping

        var title: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting"
            case .running: return "Running"
            case .stopping: return "Stopping"
            }
        }

        var symbol: String {
            switch self {
            case .stopped: return "circle"
            case .starting, .stopping: return "circle.dotted"
            case .running: return "circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .stopped: return .secondary
            case .starting, .stopping: return .orange
            case .running: return .green
            }
        }
    }

    @Published var memoryMB = 1024
    @Published var cpuCount = 2
    @Published var diskSizeGB = 8
    @Published private(set) var status: Status = .stopped
    @Published private(set) var framebuffer: UIImage?
    @Published private(set) var consoleText = ""
    @Published var errorMessage: String?
    @Published private(set) var kernelURL: URL?
    @Published private(set) var diskURL: URL?

    private var refreshTask: Task<Void, Never>?
    private var qmpSocketURL: URL?
    private var logURL: URL?
    private var screenshotURL: URL?

    var isRunning: Bool {
        status == .running || status == .stopping
    }

    var isStarting: Bool {
        status == .starting
    }

    func importFile(_ result: Result<[URL], Error>, target: ImportTarget) {
        do {
            guard let source = try result.get().first else { return }
            let hasAccess = source.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    source.stopAccessingSecurityScopedResource()
                }
            }

            let suffix = source.pathExtension.isEmpty ? "img" : source.pathExtension
            let name = target == .kernel ? "guest-kernel" : "guest-disk"
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(name)-\(UUID().uuidString).\(suffix)")
            try FileManager.default.copyItem(at: source, to: destination)

            if target == .kernel {
                kernelURL = destination
            } else {
                diskURL = destination
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createDisk() {
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("virtual-disk-\(UUID().uuidString).raw")
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let diskFile = try FileHandle(forWritingTo: destination)
            try diskFile.truncate(atOffset: UInt64(diskSizeGB) * 1024 * 1024 * 1024)
            try diskFile.close()
            diskURL = destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            errorMessage = error.localizedDescription
        }
    }

    func start() throws {
        let frameworksURL = Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        guard let libraryURL = (try? FileManager.default.contentsOfDirectory(
            at: frameworksURL,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.lastPathComponent.contains("qemu") && $0.pathExtension == "dylib" }) else {
            throw VMError.engineMissing
        }

        status = .starting
        framebuffer = nil
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let socketSuffix = String(UUID().uuidString.prefix(8))
        let socketURL = URL(fileURLWithPath: "/tmp/vi-\(socketSuffix).sock")
        let currentLogURL = documents.appendingPathComponent("qemu-guest.log")
        let currentScreenshotURL = documents.appendingPathComponent("guest-framebuffer.png")
        qmpSocketURL = socketURL
        logURL = currentLogURL
        screenshotURL = currentScreenshotURL
        try? FileManager.default.removeItem(at: socketURL)
        try? FileManager.default.removeItem(at: currentScreenshotURL)

        var arguments = [
            "qemu-system-aarch64",
            "-machine", "virt",
            "-cpu", "max",
            "-smp", "\(cpuCount)",
            "-m", "\(memoryMB)M",
            "-display", "vnc=127.0.0.1:0",
            "-device", "ramfb",
            "-serial", "null",
            "-monitor", "none",
            "-qmp", "unix:\(socketURL.path),server=on,wait=off",
            "-D", currentLogURL.path,
            "-d", "guest_errors,unimp",
            "-no-reboot"
        ]

        if let diskURL {
            arguments += ["-drive", "file=\(diskURL.path),format=raw,if=virtio"]
        }
        if let kernelURL {
            arguments += ["-kernel", kernelURL.path]
            if diskURL != nil {
                arguments += ["-append", "console=ttyAMA0 root=/dev/vda rw"]
            }
        }

        var bridgeError: NSError?
        guard QEMUBridge.start(withLibraryURL: libraryURL, arguments: arguments, error: &bridgeError) else {
            status = .stopped
            throw bridgeError ?? VMError.startFailed
        }

        status = .running
        consoleText = "QEMU TCI started · \(cpuCount) vCPU · \(memoryMB) MB RAM\n"
        startRefreshLoop()
    }

    func stop() {
        guard let qmpSocketURL else { return }
        status = .stopping
        let socketPath = qmpSocketURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            var bridgeError: NSError?
            let command: [String: Any] = ["execute": "quit"]
            let succeeded = QEMUBridge.sendCommand(command, toSocket: socketPath, response: nil, error: &bridgeError)
            DispatchQueue.main.async {
                if !succeeded {
                    self.errorMessage = bridgeError?.localizedDescription
                }
            }
        }
    }

    func captureFramebuffer(reportErrors: Bool = false) {
        guard let qmpSocketURL, let screenshotURL else { return }
        let socketPath = qmpSocketURL.path
        let imagePath = screenshotURL.path
        DispatchQueue.global(qos: .utility).async {
            let command: [String: Any] = [
                "execute": "screendump",
                "arguments": ["filename": imagePath, "format": "png"]
            ]
            var bridgeError: NSError?
            let succeeded = QEMUBridge.sendCommand(command, toSocket: socketPath, response: nil, error: &bridgeError)
            DispatchQueue.main.async {
                if succeeded, let image = UIImage(contentsOfFile: imagePath) {
                    self.framebuffer = image
                } else if reportErrors, let bridgeError {
                    self.errorMessage = bridgeError.localizedDescription
                }
            }
        }
    }

    func clearConsole() {
        consoleText = ""
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.captureFramebuffer()
                self.refreshLog()
                if !QEMUBridge.isRunning() {
                    self.status = .stopped
                    return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func refreshLog() {
        guard let logURL,
              let contents = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        consoleText = String(contents.suffix(12000))
    }
}

private enum VMError: LocalizedError {
    case engineMissing
    case startFailed

    var errorDescription: String? {
        switch self {
        case .engineMissing:
            return "The bundled ARM64 QEMU TCI engine was not found. Build the Stage 2 IPA with GitHub Actions."
        case .startFailed:
            return "QEMU could not be started. Check the build and runtime logs."
        }
    }
}
