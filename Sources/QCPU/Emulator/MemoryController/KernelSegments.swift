//
//  KernelSegments.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 13/12/2021.
//

enum KernelSegments {

    static let entryCall = MemoryComponent.Address(segment: 1, page: 0)
    static let proc      = MemoryComponent.Address(segment: 0, page: 2)

    static let skipSwap = [
        0: 0, // fork
        1: 1, // terminate
        2: 0, // swap point
        3: 0, // allocate page
        4: 0, // allocate segment
        5: 0, // drop
        6: 0, // set data target
        7: 0, // reset data target
        8: 0, // segment load
        9: 0, // call
        10: 1 // return
    ]

    static func kernelCallAddress(fromInstruction instruction: Int) -> MemoryComponent.Address {
        switch instruction {
            case 0:  return .init(segment: 2, page: 0)
            case 1:  return .init(segment: 2, page: 2)
            case 2:  return .init(segment: 2, page: 3)
            case 9:  return .init(segment: 2, page: 4)
            case 10: return .init(segment: 2, page: 5)
            default:
                CLIStateController.terminate("Runtime error: invalid or unimplemented kernel call (\(instruction))")
        }
    }
}
