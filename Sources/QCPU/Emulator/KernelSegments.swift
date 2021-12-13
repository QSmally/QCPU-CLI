//
//  KernelSegments.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 13/12/2021.
//

enum KernelSegments {

    static let entryCall = MemoryComponent.Address(upper: 1, lower: 0)

    static func kernelCallAddress(fromInstruction instruction: Int) -> MemoryComponent.Address {
        switch instruction {
            case 0: return .init(segment: 2, page: 0)
            case 1: return .init(segment: 2, page: 2)
            case 2: return .init(segment: 2, page: 3)
            default:
                CLIStateController.terminate("Runtime error: invalid or unimplemented kernel call (\(instruction))")
        }
    }
}
