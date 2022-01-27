//
//  MMU.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

final class MMU {

    var processId = 0
    var instructionSegment = 0 { didSet { instructionCacheValidated = false } }
    var dataContext: Int? = nil { didSet { dataCacheValidated = false } }
    var kernelDataContext: Int? = nil { didSet { dataCacheValidated = false } }

    var instructionCacheValidated = true
    var dataCacheValidated = true
    var dataCacheNeedsStore = false

    var callStack = [Int]()
    var parameterStack = [Int]()

    unowned var emulator: EmulatorStateController

    init(emulator: EmulatorStateController) {
        self.emulator = emulator
    }

    func execute(instruction: Int) {
        switch instruction {
            case 0: // instruction segment store
                instructionSegment = emulator.accumulator
                emulator.nextCycle()

            case 1: // append segment to call stack
                callStack.append(instructionSegment)
                emulator.nextCycle()

            case 2: // data segment store
                dataContext = emulator.accumulator
                emulator.nextCycle()

            case 3: // kernel data segment store
                kernelDataContext = emulator.accumulator
                emulator.nextCycle()

            case 4: // load kernel instruction page
                let addressTarget = KernelSegments.kernelCallAddress(fromInstruction: emulator.accumulator)
                let loadedComponent = emulator.memory.locate(address: addressTarget)

                instructionSegment = addressTarget.segment
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty(atAddress: addressTarget)
                emulator.nextCycle(0)

                instructionCacheValidated = true

            case 5: // exit kernel mode
                emulator.mode = .application
                kernelDataContext = nil
                emulator.nextCycle()

            case 6: // pid register
                dataContext = nil
                processId = emulator.accumulator
                emulator.nextCycle()

            case 7: // pid load
                emulator.accumulator = processId
                emulator.nextCycle()

            default:
                CLIStateController.terminate("Runtime error: unrecognised MMU action (\(instruction))")
        }
    }

    func applicationKernelCall(operand: Int) {
        guard emulator.mode == .application else {
            CLIStateController.terminate("Runtime error: kernel cannot call a nested system routine")
        }

        let skipsSwap = KernelSegments.skipSwap[operand] ?? 0
        parameterStack.append((operand << 1) | skipsSwap)

        let loadedComponent = emulator.memory.locate(address: KernelSegments.entryCall)
        instructionSegment = KernelSegments.entryCall.segment

        emulator.mode = .kernel
        emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty(atAddress: KernelSegments.entryCall)
        emulator.nextCycle(KernelSegments.entryCall.line)

        instructionCacheValidated = true
    }
}
