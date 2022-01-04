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
    var mmuArgumentStack = [Int]()

    unowned var emulator: EmulatorStateController

    init(emulator: EmulatorStateController) {
        self.emulator = emulator
    }

    func pin(at address: Int) {
        switch address {
            case 0: // data target
                dataContext = mmuArgumentStack[0]
                emulator.nextCycle()

            case 1: // kernel data target
                kernelDataContext = mmuArgumentStack[0]
                emulator.nextCycle()

            case 2: // intermediate load
                let addressTarget = MemoryComponent.Address(
                    upper: mmuArgumentStack[0],
                    lower: mmuArgumentStack[optional: 1] ?? 0)
                let loadedComponent = emulator.memory.at(address: addressTarget)

                instructionSegment = addressTarget.segment
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty(atAddress: addressTarget)
                emulator.nextCycle(addressTarget.line)

                instructionCacheValidated = true

            case 3: // kernel intermediate load
                let addressTarget = KernelSegments.kernelCallAddress(fromInstruction: mmuArgumentStack[0])
                let loadedComponent = emulator.memory.at(address: addressTarget)

                instructionSegment = addressTarget.segment
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty(atAddress: addressTarget)
                emulator.nextCycle(0)

                instructionCacheValidated = true

            case 4: // exit intermediate load
                let addressTarget = MemoryComponent.Address(
                    upper: mmuArgumentStack[0],
                    lower: mmuArgumentStack[optional: 1] ?? 0)
                let loadedComponent = emulator.memory.at(address: addressTarget)

                instructionSegment = addressTarget.segment
                emulator.mode = .application
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty(atAddress: addressTarget)
                emulator.nextCycle(addressTarget.line)

                kernelDataContext = nil
                instructionCacheValidated = true

            case 5: // pid register
                processId = emulator.accumulator
                emulator.nextCycle()

            case 6: // pid load
                emulator.accumulator = processId
                emulator.nextCycle()

            default:
                CLIStateController.terminate("Runtime error: unrecognised MMU action (pin \(address))")
        }

        mmuArgumentStack.removeAll(keepingCapacity: true)
    }

    func applicationKernelCall(operand: Int) {
        guard emulator.mode == .application else {
            CLIStateController.terminate("Runtime error: kernel cannot call a nested system routine")
        }

        let skipsSwap = KernelSegments.skipSwap[operand] ?? 0
        parameterStack.append((operand << 1) | skipsSwap)

        let loadedComponent = emulator.memory.at(address: KernelSegments.entryCall)
        instructionSegment = KernelSegments.entryCall.segment

        emulator.mode = .kernel
        emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty(atAddress: KernelSegments.entryCall)
        emulator.nextCycle(KernelSegments.entryCall.line)

        instructionCacheValidated = true
    }
}
