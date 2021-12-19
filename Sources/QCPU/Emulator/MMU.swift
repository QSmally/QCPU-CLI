//
//  MMU.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

final class MMU {

    var intermediateSegmentAddress = 0

    var parameters = [Int]()
    var mmuArgumentStack = [Int]()
    var addressCallStack = [Int]()
    var contextStack = [Int]()

    var contextStore = [Int: [Int]]()

    unowned var emulator: EmulatorStateController

    init(emulator: EmulatorStateController) {
        self.emulator = emulator
    }

    func store(at address: Int) {
        switch address {
            case 0:
                emulator.mode == .kernel ?
                    contextStack.append(emulator.accumulator) :
                    emulator.outputStream.append(emulator.accumulator)
            default:
                emulator.outputStream.append(emulator.accumulator)
        }
    }

    func load(from address: Int) {
        guard emulator.mode == .kernel else {
            CLIStateController.newline("load (\(address)):")
            return
        }

        switch address {
            case 0: emulator.accumulator = contextStack.popLast() ?? 0
            default:
                CLIStateController.terminate("Runtime error: unrecognised kernel action (load \(address))")
        }
    }

    func pin(at address: Int) {
        guard emulator.mode == .kernel else {
            CLIStateController.newline("pin (\(address))")
            emulator.nextCycle()
            return
        }

        switch address {
            case 0: // data store
                let addressTarget = MemoryComponent.Address(
                    upper: mmuArgumentStack[0],
                    lower: mmuArgumentStack[1])

                emulator.memory.removeAll { $0.address.equals(to: addressTarget, basedOn: .page) }
                emulator.memory.append(emulator.dataComponent.clone())
                emulator.nextCycle()

            case 1: // data load
                let addressTarget = MemoryComponent.Address(
                    upper: mmuArgumentStack[0],
                    lower: mmuArgumentStack[1])
                let loadedComponentCopy = emulator.memory
                    .first { $0.address.equals(to: addressTarget, basedOn: .page) }?
                    .clone()

                emulator.dataComponent = loadedComponentCopy ?? MemoryComponent.empty()
                emulator.nextCycle()

            case 2: // intermediate load
                let addressTarget = MemoryComponent.Address(
                    upper: mmuArgumentStack[0],
                    lower: mmuArgumentStack[optional: 1] ?? 0)
                let loadedComponent = emulator.memory.first { $0.address.equals(to: addressTarget, basedOn: .page) }

                intermediateSegmentAddress = addressTarget.segment
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty()
                emulator.nextCycle(Int(addressTarget.line))

            case 3: // kernel intermediate load
                let addressTarget = KernelSegments.kernelCallAddress(fromInstruction: mmuArgumentStack[0])
                let loadedComponent = emulator.memory.first { $0.address.equals(to: addressTarget, basedOn: .page) }

                intermediateSegmentAddress = addressTarget.segment
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty()
                emulator.nextCycle(0)

            case 4: // exit intermediate load
                let addressTarget = MemoryComponent.Address(
                    upper: mmuArgumentStack[0],
                    lower: mmuArgumentStack[optional: 1] ?? 0)
                let loadedComponent = emulator.memory.first { $0.address.equals(to: addressTarget, basedOn: .page) }

                intermediateSegmentAddress = addressTarget.segment
                emulator.mode = .application
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty()
                emulator.nextCycle(Int(addressTarget.line))

            case 5: // context snapshot
                contextStore[mmuArgumentStack[0]] = contextStack
                contextStack.removeAll(keepingCapacity: true)
                emulator.nextCycle()

            case 6: // context restore
                contextStack = contextStore[mmuArgumentStack[0]] ?? []
                emulator.nextCycle()

            default:
                CLIStateController.terminate("Runtime error: unrecognised MMU action (pin \(address))")
        }

        mmuArgumentStack.removeAll(keepingCapacity: true)
    }

    func applicationKernelCall() {
        guard emulator.mode == .application else {
            CLIStateController.terminate("Runtime error: kernel cannot call a nested system call")
        }

        let loadedComponent = emulator.memory.first { $0.address.equals(to: KernelSegments.entryCall, basedOn: .page) }
        intermediateSegmentAddress = Int(KernelSegments.entryCall.segment)

        emulator.mode = .kernel
        emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty()
        emulator.nextCycle(Int(KernelSegments.entryCall.line))
    }
}
