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
    var pointer = (local: 0, storage: false, propagateCarry: false)

    var modifierCache: (
        statement: MemoryComponent.Statement,
        arguments: [Int])!

    // Clock queue
    var clock: DispatchSourceTimer?

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

    init(memoryComponents: [MemoryComponent]) {
        self.memory = memoryComponents
    }

    func startClockTimer(withSpeed speed: Double) {
        guard let entry = memory.first(where: {
            $0.address.segment == 0 && $0.address.page == 0
        }) else {
            CLIStateController.terminate("Fatal error: no program entry (0, 0)")
        }

        accumulator = 0
        instructionComponent = entry
        updateUI()

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

        if modifierCache == nil {
            guard statement.representsCompiled != nil else {
                CLIStateController.terminate("Runtime error: instruction '\(statement.value)' does not have a compiled instruction")
            }

            let bytes = pointer.storage ?
                0 :
                statement.representsCompiled?.amountSecondaryBytes ?? 0

            if bytes > 0 {
                modifierCache = (statement: statement, arguments: [])
                nextCycle()
                updateUI()
                return
            }

            clockTick(executing: statement, arguments: [])
        } else {
            modifierCache.arguments.append(statement.value)
            
            if modifierCache.arguments.count == modifierCache.statement.representsCompiled.amountSecondaryBytes {
                clockTick(
                    executing: modifierCache.statement,
                    arguments: modifierCache.arguments)
                modifierCache = nil
            } else {
                nextCycle()
            }
        }

        updateUI()
    }

    func nextCycle(_ line: Int? = nil) {
        self.line = line ?? self.line + 1
    }

    func terminate() {
        clock?.suspend()
        CLIStateController.terminate()
    }
}
