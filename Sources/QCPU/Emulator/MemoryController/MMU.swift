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

    lazy var kernelCallEntry: MemoryComponent.Address? = {
        guard let address = emulator.defaults.kernel_entryCall else {
            return nil
        }

        guard address.count == 3 else {
            CLIStateController.terminate("Runtime error (defaults): kernel entry point must be an array with a size of 3")
        }

        return .init(
            segment: address[0],
            page: address[1],
            line: address[2])
    }()

    lazy var kernelCallMapping: [Int: MemoryComponent.Address] = {
        // TODO: add failsafe if the size of the array isn't equal to 2
        emulator.defaults.kernel_mapping?
            .mapValues { .init(segment: $0[0], page: $0[1]) } ?? [:]
    }()

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
                guard let addressTarget = kernelCallMapping[emulator.accumulator] else {
                    CLIStateController.terminate("Runtime error: invalid or unimplemented kernel call (\(emulator.accumulator))")
                }

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
        guard let kernelCallEntry = kernelCallEntry else {
            CLIStateController.terminate("Runtime error: unable to find kernel handle entry point")
        }

        guard emulator.mode == .application else {
            CLIStateController.terminate("Runtime error: kernel cannot call a nested system routine")
        }

        parameterStack.append(operand)

        let loadedComponent = emulator.memory.locate(address: kernelCallEntry)
        instructionSegment = kernelCallEntry.segment

        emulator.mode = .kernel
        emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty(atAddress: kernelCallEntry)
        emulator.nextCycle(kernelCallEntry.line)

        instructionCacheValidated = true
    }
}
