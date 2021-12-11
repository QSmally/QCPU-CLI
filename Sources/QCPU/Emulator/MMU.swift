//
//  MMU.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

final class MMU {

    var intermediateSegmentAddress = 0

    var argumentStack = [Int]()
    var addressCallStack = [Int]()
    var contextStack = [Int]()
    var contextStore = [Int: [Int]]()

    unowned var emulator: EmulatorStateController

    lazy var kernelEntry = {
        MemoryComponent.Address(upper: 1, lower: 0)
    }()

    init(emulator: EmulatorStateController) {
        self.emulator = emulator
    }

    func store(at address: Int) {
        guard emulator.mode == .kernel else {
            CLIStateController.newline("application port store (port \(address)): \(emulator.accumulator)")
            return
        }

        switch address {
            case 0: contextStack.append(emulator.accumulator)
            case 1: argumentStack.append(emulator.accumulator)
            default:
                CLIStateController.newline("port store (\(address)): \(emulator.accumulator)")
        }
    }

    func load(from address: Int) {
        guard emulator.mode == .kernel else {
            CLIStateController.newline("application port load (\(address)):")
            return
        }

        switch address {
            case 0: emulator.accumulator = contextStack.popLast() ?? 0
            case 1: emulator.accumulator = argumentStack.popLast() ?? 0
            default:
                CLIStateController.newline("port load (\(address)):")
        }
    }

    func pin(at address: Int) {
        guard emulator.mode == .kernel else {
            CLIStateController.newline("application pin (\(address))")
            emulator.nextCycle()
            return
        }

        switch address {
            case 0: // data store
                let addressTarget = MemoryComponent.Address(
                    upper: argumentStack[0],
                    lower: argumentStack[1])

                emulator.memory.removeAll { $0.address.equals(to: addressTarget, basedOn: .page) }
                emulator.memory.append(emulator.dataComponent.clone())

            case 1: // data load
                let addressTarget = MemoryComponent.Address(
                    upper: argumentStack[0],
                    lower: argumentStack[1])
                let loadedComponentCopy = emulator.memory
                    .first { $0.address.equals(to: addressTarget, basedOn: .page) }?
                    .clone()

                emulator.dataComponent = loadedComponentCopy ?? MemoryComponent.empty()

            case 2: // intermediate load
                let addressTarget = MemoryComponent.Address(
                    upper: argumentStack[0],
                    lower: argumentStack[optional: 1] ?? 0)
                let loadedComponent = emulator.memory.first { $0.address.equals(to: addressTarget, basedOn: .page) }

                intermediateSegmentAddress = argumentStack[0]
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty()
                emulator.nextCycle(Int(addressTarget.line))

            case 3: // kernel intermediate load
                let addressTarget = kernelCallAddress()
                let loadedComponent = emulator.memory.first { $0.address.equals(to: addressTarget, basedOn: .page) }

                intermediateSegmentAddress = argumentStack[0]
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty()
                emulator.nextCycle(0)

            case 4: // exit intermediate load
                let addressTarget = MemoryComponent.Address(
                    upper: argumentStack[0],
                    lower: argumentStack[optional: 1] ?? 0)
                let loadedComponent = emulator.memory.first { $0.address.equals(to: addressTarget, basedOn: .page) }

                intermediateSegmentAddress = argumentStack[0]
                emulator.mode = .application
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty()
                emulator.nextCycle(Int(addressTarget.line))

            case 5: // context snapshot
                contextStore[argumentStack[0]] = contextStack
                contextStack.removeAll(keepingCapacity: true)
                emulator.nextCycle()

            case 6: // context restore
                contextStack = contextStore[argumentStack[0]] ?? []
                emulator.nextCycle()

            default:
                CLIStateController.newline("pin (\(address))")
                emulator.nextCycle()
        }

        argumentStack.removeAll(keepingCapacity: true)
    }

    func applicationKernelCall(from instruction: MemoryComponent.Statement.Instruction, withArguments arguments: [Int] = []) {
        switch instruction {
            case .ent: // enter
                let loadedComponent = emulator.memory.first { $0.address.equals(to: kernelEntry, basedOn: .page) }

                intermediateSegmentAddress = Int(kernelEntry.segment)

                emulator.mode = .kernel
                emulator.instructionComponent = loadedComponent ?? MemoryComponent.empty()
                emulator.nextCycle(Int(kernelEntry.line))

            case .dds: // direct data store
                fallthrough
            case .ddl: // direct data load
                fallthrough
            case .ibl: // intermediate block load
                CLIStateController.terminate("Runtime error: unimplemented kernel instruction (\(String(describing: instruction).uppercased())")
                break
            default:
                CLIStateController.terminate("Runtime error: invalid kernel instruction (\(String(describing: instruction).uppercased())")
        }
    }

    private func kernelCallAddress() -> MemoryComponent.Address {
        switch argumentStack[0] {
            case 0: return .init(segment: 2, page: 0)
            case 1: return .init(segment: 2, page: 2)
            case 2: return .init(segment: 2, page: 3)
            default:
                CLIStateController.terminate("Runtime error: invalid or unimplemented kernel call (\(argumentStack[0])")
        }
    }
}
