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
    var immediateStatement: MemoryComponent.Statement!

    // Clock and UI
    var clock: DispatchSourceTimer?
    var renderedStream = String()

    // Memory controller
    lazy var mmu = MMU(emulator: self)

    var memory: [MemoryComponent]
    var instructionComponent: MemoryComponent!
    var dataComponent: MemoryComponent!

    // CPU memory
    var accumulator = 0 { willSet { updateConditionFlags(changedTo: newValue) } }

    var flags = [Int: Bool]()
    var registers = [Int: Int]()
    var outputStream = [Int]()

    enum ExecutionContext {
        case application,
             kernel
    }

    class Modifiers {
        var pointer = 0
        var propagateCarry = false
    }

    init(memoryComponents: [MemoryComponent]) {
        self.memory = memoryComponents
    }

    func startClockTimer(withSpeed speed: Double) {
        guard let entry = memory.locate(address: MemoryComponent.Address(segment: 0, page: 0)) else {
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
        guard let statement = instructionComponent.binary[line] else {
            nextCycle()
            return
        }

        if let immediateStatement = immediateStatement {
            clockTick(
                executing: immediateStatement,
                argument: statement.value)
            self.immediateStatement = nil
        } else {
            guard let compiledStatement = statement.representsCompiled else {
                CLIStateController.terminate("Runtime error: byte '\(statement.formatted)' (line \(line)) isn't a compiled instruction")
            }

            if compiledStatement.hasSecondaryByte {
                immediateStatement = statement
                nextCycle()
                return
            }

            clockTick(executing: statement, argument: 0)
        }
    }

    func nextCycle(_ line: Int? = nil) {
        self.line = line ?? self.line + 1
        cycles += 1

        if self.line >> 5 != 0 {
            instructionCacheController(page: instructionComponent.address.page + 1)
            self.line = 0
        }

        updateUI()
    }

    func terminate() {
        clock?.suspend()
        CLIStateController.terminate()
    }
}
