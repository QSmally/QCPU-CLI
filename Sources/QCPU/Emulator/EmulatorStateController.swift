//
//  EmulatorStateController.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

import Foundation

final class EmulatorStateController {

    // State
    var line = 0
    var cycles: UInt = 0
    var mode: ExecutionContext = .kernel

    var modifiers = Modifiers()

    var immediateCache: (
        statement: MemoryComponent.Statement,
        bytesNeeded: Int,
        arguments: [Int])!

    // Clock and UI
    var clock: DispatchSourceTimer?
    var renderedStream = String()

    // Memory controller
    lazy var mmu = MMU(emulator: self)

    var memory: [MemoryComponent]
    var instructionComponent: MemoryComponent!
    var dataComponent: MemoryComponent!

    // CPU memory
    var condition = 0
    var accumulator = 0 { willSet { updateConditionFlags(changedTo: newValue) } }

    var flags = [Int: Bool]()
    var registers = [Int: Int]()
    var outputStream = [Int]()

    enum ExecutionContext {
        case application,
             kernel
    }

    class Modifiers {
        var flags = true
        var propagateCarry = false
    }

    init(memoryComponents: [MemoryComponent]) {
        self.memory = memoryComponents
    }

    func startClockTimer(withSpeed speed: Double) {
        guard let entry = memory.at(address: MemoryComponent.Address(segment: 0, page: 0)) else {
            CLIStateController.terminate("Fatal error: no program entry (0, 0)")
        }

        // Initialisation
        for register in 1...7 {
            registers[register] = 0
        }

        accumulator = 0
        instructionComponent = entry
        updateUI()

        // Clock
        let instructionQueue = DispatchQueue(label: "eu.qbot.qcpu-cli.clock")
        clock = DispatchSource.makeTimerSource(queue: instructionQueue)
        clock?.setEventHandler(handler: clockTickMask)
        clock?.schedule(deadline: .now() + 0.25, repeating: 1 / speed)

        clock?.resume()
        RunLoop.main.run()
    }

    func clockTickMask() {
        let statement = instructionComponent.compiled[line] ??
            MemoryComponent.Statement(represents: .nop, operand: 0)
        cycles += 1

        if immediateCache == nil {
            guard statement.representsCompiled != nil else {
                CLIStateController.terminate("Runtime error: byte '\(statement.value)' isn't a compiled instruction")
            }

            let bytes = statement.representsCompiled?
                .amountSecondaryBytes(operand: statement.operand) ?? 0

            if bytes > 0 {
                immediateCache = (
                    statement: statement,
                    bytesNeeded: bytes,
                    arguments: [])
                nextCycle()
                return
            }

            clockTick(executing: statement, arguments: [])
        } else {
            immediateCache.arguments.append(statement.value)

            if immediateCache.arguments.count == immediateCache.bytesNeeded {
                clockTick(
                    executing: immediateCache.statement,
                    arguments: immediateCache.arguments)
                immediateCache = nil
            } else {
                nextCycle()
            }
        }
    }

    func nextCycle(_ line: Int? = nil) {
        self.line = line ?? self.line + 1
        updateUI()
    }

    func terminate() {
        clock?.suspend()
        CLIStateController.terminate()
    }
}
