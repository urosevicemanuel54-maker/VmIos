//
//  GuestCPU.swift
//  Vortex
//
//  Swift surface for the ARM64 interpreter: registers, step/run control,
//  breakpoints, disassembly and typed error reporting.
//

import Foundation

final class GuestCPU {
    struct Snapshot {
        var pc: UInt64 = 0
        var sp: UInt64 = 0
        var nzcv: UInt32 = 0
        var instructionsExecuted: UInt64 = 0
        var decodeHits: UInt64 = 0
        var decodeMisses: UInt64 = 0
        var errorCount: UInt64 = 0
        var instructionsPerSecond: UInt64 = 0
        var halted: Bool = false
        var errorPending: Bool = false

        var flagN: Bool { (nzcv & 8) != 0 }
        var flagZ: Bool { (nzcv & 4) != 0 }
        var flagC: Bool { (nzcv & 2) != 0 }
        var flagV: Bool { (nzcv & 1) != 0 }

        var decodeTotal: UInt64 { decodeHits + decodeMisses }

        var decodeHitRate: Double {
            let total = decodeTotal
            guard total > 0 else { return 0 }
            return Double(decodeHits) / Double(total)
        }
    }

    enum ErrorKind: UInt32 {
        case none = 0
        case unimplemented = 1
        case memory = 2
        case alignment = 3

        var label: String {
            switch self {
            case .none: return "None"
            case .unimplemented: return "Unimplemented instruction"
            case .memory: return "Memory access"
            case .alignment: return "Alignment"
            }
        }
    }

    struct ErrorReport {
        let kind: ErrorKind
        let pc: UInt64
        let instruction: UInt32
        let message: String
    }

    struct DisassemblyLine: Identifiable {
        let pc: UInt64
        let instruction: UInt32
        let text: String
        var hasBreakpoint: Bool
        var id: UInt64 { pc }
    }

    struct VectorRegister: Identifiable {
        let index: Int
        let low: UInt64
        let high: UInt64
        var id: Int { index }
    }

    private var pointer: OpaquePointer?

    init(pointer: OpaquePointer?) {
        self.pointer = pointer
    }

    /// Called by the core owner before the C core is destroyed.
    func detach() {
        pointer = nil
    }

    var isValid: Bool { pointer != nil }

    // MARK: - Control

    @discardableResult
    func step() -> Bool {
        guard let pointer else { return false }
        return vortex_cpu_step(pointer)
    }

    /// Executes at most `maxInstructions`; returns how many actually ran.
    @discardableResult
    func run(maxInstructions: Int) -> Int {
        guard let pointer, maxInstructions > 0 else { return 0 }
        return vortex_cpu_run(pointer, maxInstructions)
    }

    func reset() {
        guard let pointer else { return }
        vortex_cpu_reset(pointer)
    }

    func clearError() {
        guard let pointer else { return }
        vortex_cpu_clear_last_error(pointer)
    }

    // MARK: - State

    var snapshot: Snapshot {
        guard let pointer else { return Snapshot() }
        var raw = vortex_cpu_snapshot()
        vortex_cpu_copy_snapshot(pointer, &raw)
        return Snapshot(pc: raw.pc,
                        sp: raw.sp,
                        nzcv: raw.nzcv,
                        instructionsExecuted: raw.instructions_executed,
                        decodeHits: raw.decode_hits,
                        decodeMisses: raw.decode_misses,
                        errorCount: raw.error_count,
                        instructionsPerSecond: raw.instructions_per_second,
                        halted: raw.halted,
                        errorPending: raw.error_pending)
    }

    var lastError: ErrorReport? {
        guard let pointer else { return nil }
        var kind: UInt32 = 0
        var pc: UInt64 = 0
        var instruction: UInt32 = 0
        var buffer = [CChar](repeating: 0, count: 192)

        let hasError = vortex_cpu_copy_last_error(pointer, &kind, &pc, &instruction, &buffer, buffer.count)
        guard hasError else { return nil }
        return ErrorReport(kind: ErrorKind(rawValue: kind) ?? .none,
                           pc: pc,
                           instruction: instruction,
                           message: String(cString: buffer))
    }

    func readRegister(_ index: Int) -> UInt64 {
        guard let pointer else { return 0 }
        return vortex_cpu_read_register(pointer, UInt32(max(0, min(index, 31))))
    }

    func writeRegister(_ index: Int, value: UInt64) {
        guard let pointer else { return }
        vortex_cpu_write_register(pointer, UInt32(max(0, min(index, 31))), value)
    }

    func vectorRegisters() -> [VectorRegister] {
        guard let pointer else { return [] }
        var words = [UInt64](repeating: 0, count: 64)
        words.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                vortex_cpu_copy_vector_registers(pointer, base)
            }
        }
        return (0..<32).map { index in
            VectorRegister(index: index, low: words[index * 2], high: words[index * 2 + 1])
        }
    }

    func memorySize() -> Int {
        guard let pointer else { return 0 }
        return vortex_cpu_memory_size(pointer)
    }

    // MARK: - Memory

    @discardableResult
    func load(program: [UInt32], at address: UInt64) -> Bool {
        guard let pointer else { return false }
        return program.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return vortex_cpu_write_memory(pointer, address, base, buffer.count)
        }
    }

    func readInstruction(at address: UInt64) -> UInt32? {
        guard let pointer else { return nil }
        var instruction: UInt32 = 0
        guard vortex_cpu_read_instruction(pointer, address, &instruction) else { return nil }
        return instruction
    }

    // MARK: - Breakpoints

    func hasBreakpoint(at pc: UInt64) -> Bool {
        guard let pointer else { return false }
        return vortex_cpu_has_breakpoint(pointer, pc)
    }

    @discardableResult
    func addBreakpoint(at pc: UInt64) -> Bool {
        guard let pointer else { return false }
        return vortex_cpu_add_breakpoint(pointer, pc)
    }

    @discardableResult
    func removeBreakpoint(at pc: UInt64) -> Bool {
        guard let pointer else { return false }
        return vortex_cpu_remove_breakpoint(pointer, pc)
    }

    func clearBreakpoints() {
        guard let pointer else { return }
        vortex_cpu_clear_breakpoints(pointer)
    }

    // MARK: - Disassembly

    func disassembly(from startPC: UInt64, count: Int) -> [DisassemblyLine] {
        guard count > 0 else { return [] }
        var lines: [DisassemblyLine] = []
        for index in 0..<count {
            let pc = startPC & ~3 &+ UInt64(index) * 4
            guard let instruction = readInstruction(at: pc) else {
                lines.append(DisassemblyLine(pc: pc,
                                             instruction: 0,
                                             text: "— outside guest memory —",
                                             hasBreakpoint: false))
                continue
            }
            lines.append(DisassemblyLine(pc: pc,
                                         instruction: instruction,
                                         text: Self.disassemble(word: instruction, pc: pc),
                                         hasBreakpoint: hasBreakpoint(at: pc)))
        }
        return lines
    }

    static func disassemble(word: UInt32, pc: UInt64) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        _ = vortex_cpu_disassemble(word, pc, &buffer, buffer.count)
        return String(cString: buffer)
    }

    // MARK: - Demo program

    /// Hand-assembled: sum 1...10 into x0, then spin.
    ///
    ///   mov x0, #0          ; accumulator
    ///   mov x1, #1          ; counter
    /// loop:
    ///   add x0, x0, x1
    ///   add x1, x1, #1
    ///   cmp x1, #11
    ///   b.ne loop
    ///   b .
    static let demoProgram: [UInt32] = [
        0xD2800000, // mov x0, #0
        0xD2800021, // mov x1, #1
        0x8B010000, // add x0, x0, x1
        0x91000421, // add x1, x1, #1
        0xF1002C3F, // cmp x1, #11
        0x540FFFA1, // b.ne 0x8
        0x14000000  // b .
    ]
}
