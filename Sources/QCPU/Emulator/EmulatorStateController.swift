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
    var mode: ExecutionContext = .kernel
    var modifierCache: (
        instruction: MemoryComponent.CompiledStatement,
        arguments: [Int])?

    // Clock queue
    var clock: DispatchSourceTimer?

    // Memory controller
    lazy var mmu = MMU(emulator: self)

    var memory: [MemoryComponent]
    var instructionComponent: MemoryComponent!
    var dataComponent: MemoryComponent!

    var condition = 0
    var accumulator = 0 { didSet { updateConditionFlags() } }
    var flags = [Int: Int]()
    var registers = [Int: Int]()

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
            CLIStateController.terminate("Fatal error: no program entry (segment 0, page 0)")
        }

        instructionComponent = entry

        let instructionQueue = DispatchQueue(label: "eu.qbot.qcpu-cli.instruction_clock_timer")
        clock = DispatchSource.makeTimerSource(queue: instructionQueue)
        clock?.setEventHandler(handler: clockTickMask)
        clock?.schedule(deadline: .now() + 0.25, repeating: 1 / speed)

        clock?.resume()
        RunLoop.main.run()
    }

    func clockTickMask() {
        let statement = instructionComponent.compiled.count > line ?
            instructionComponent.compiled[line] :
            MemoryComponent.CompiledStatement(instruction: .nop, operand: nil)

        // TODO: process this beforehand to save up on execution time.
        if let modifierCache = modifierCache, statement.instruction != .word {
            CLIStateController.terminate("Runtime error: expected argument after '\(modifierCache.instruction.display)', not '\(statement.display)'")
        }

        if statement.instruction.amountSecondaryBytes > 0 {
            modifierCache = (instruction: statement, arguments: [])
            nextCycle()
            return
        }

        if let modifierCache = modifierCache {
            self.modifierCache!.arguments.append(statement.operand)

            if modifierCache.arguments.count + 1 >= modifierCache.instruction.instruction.amountSecondaryBytes {
                clockTick(
                    executing: modifierCache.instruction,
                    arguments: self.modifierCache!.arguments)
                self.modifierCache = nil
            } else {
                nextCycle()
            }
        } else {
            clockTick(executing: statement, arguments: [])
        }
    }

    func nextCycle(_ line: Int? = nil) {
        self.line = line ?? self.line + 1
    }

    func terminate() {
        clock?.suspend()
        CLIStateController.terminate()
    }
}
