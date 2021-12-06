//
//  Instruction.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

import Dispatch

extension EmulatorStateController {
    func clockTick(executing instruction: MemoryComponent.CompiledStatement) {
        print("\(line) \(instruction.display)")
        line == 31 ?
            terminate() :
            nextCycle()
    }
}
