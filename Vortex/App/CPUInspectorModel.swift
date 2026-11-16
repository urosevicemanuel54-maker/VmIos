//
//  CPUInspectorModel.swift
//  Vortex
//
//  Drives the guest CPU for the inspector: single step, chunked run with a
//  timer, breakpoints and measured instructions per second.
//

import Foundation
import QuartzCore

final class CPUInspectorModel: ObservableObject {
    @Published private(set) var snapshot = GuestCPU.Snapshot()
    @Published private(set) var registers: [UInt64] = Array(repeating: 0, count: 31)
    @Published private(set) var vectors: [GuestCPU.VectorRegister] = []
    @Published private(set) var disassembly: [GuestCPU.DisassemblyLine] = []
    @Published private(set) var lastError: GuestCPU.ErrorReport?
    @Published private(set) var isRunning = false
    @Published private(set) var memorySizeText = ""
    @Published private(set) var executedBeforeRun: UInt64 = 0

    @Published var instructionsPerChunk: Int = 100_000

    let cpu: GuestCPU

    private var timer: Timer?
    private let disassemblyLineCount = 14
    private let chunkInterval: TimeInterval = 1.0 / 30.0

    init(cpu: GuestCPU) {
        self.cpu = cpu
        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Actions

    func step() {
        stop()
        cpu.step()
        refresh()
    }

    func start() {
        guard !isRunning else { return }
        if snapshot.errorPending || snapshot.halted {
            cpu.clearError()
        }
        isRunning = true
        executedBeforeRun = cpu.snapshot.instructionsExecuted

        let timer = Timer(timeInterval: chunkInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        refresh()
    }

    func toggleRunning() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func reset() {
        stop()
        cpu.reset()
        refresh()
    }

    func loadDemoProgram() {
        stop()
        _ = cpu.load(program: GuestCPU.demoProgram, at: 0)
        cpu.reset()
        refresh()
    }

    func clearError() {
        stop()
        cpu.clearError()
        refresh()
    }

    func toggleBreakpoint(at pc: UInt64) {
        if cpu.hasBreakpoint(at: pc) {
            cpu.removeBreakpoint(at: pc)
        } else {
            cpu.addBreakpoint(at: pc)
        }
        refresh()
    }

    func clearBreakpoints() {
        cpu.clearBreakpoints()
        refresh()
    }

    // MARK: - Frame

    private func tick() {
        let executed = cpu.run(maxInstructions: instructionsPerChunk)
        refresh()
        if executed < instructionsPerChunk {
            // Stopped on a breakpoint, an error or a halt.
            stop()
        }
    }

    func refresh() {
        let state = cpu.snapshot
        snapshot = state
        registers = (0..<31).map { cpu.readRegister($0) }
        vectors = cpu.vectorRegisters()
        lastError = cpu.lastError
        disassembly = cpu.disassembly(from: state.pc, count: disassemblyLineCount)
        memorySizeText = Self.formatBytes(cpu.memorySize())
    }

    // MARK: - Formatting

    static func hex(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }

    static func shortHex(_ value: UInt64) -> String {
        String(format: "0x%04llx", value & 0xFFFF)
    }

    static func formatBytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }

    static func formatRate(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(text) insn/s"
    }
}
