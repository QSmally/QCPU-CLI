//
//  Instruction.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

import Dispatch

extension EmulatorStateController {
    func clockTick(executing statement: MemoryComponent.CompiledStatement, arguments: [Int]) {
        print("\(line - statement.instruction.amountSecondaryBytes) \(statement.display)")

        line == 31 ?
            terminate() :
            nextCycle()
    }
}
