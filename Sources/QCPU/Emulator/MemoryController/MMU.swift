//
//  MMU.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

final class MMU {

    var processId = 0
    var instructionSegment = 0
    var dataContext: Int? = nil

    var callStack = [Int]()
    var parameterStack = [Int]()
    var mmuArgumentStack = [Int]()

    unowned var emulator: EmulatorStateController

    init(emulator: EmulatorStateController) {
        self.emulator = emulator
    }

    func pin(at address: Int) {
        /*
        switch address {
            case 0: // data target
            case 1: // intermediate load
            case 2: // kernel intermediate load
            case 3: // exit intermediate load
            case 4: // pid register
            case 5: // pid load

            default:
                CLIStateController.terminate("Runtime error: unrecognised MMU action (pin \(address))")
        }
        */

        mmuArgumentStack.removeAll(keepingCapacity: true)
    }

    func applicationKernelCall() {
        guard emulator.mode == .application else {
            CLIStateController.terminate("Runtime error: kernel cannot call a nested system routine")
        }

        let loadedComponent = emulator.memory.at(address: KernelSegments.entryCall)
        instructionSegment = Int(KernelSegments.entryCall.segment)

        emulator.mode = .kernel
        emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty()
        emulator.nextCycle(Int(KernelSegments.entryCall.line))
    }
}
