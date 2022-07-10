//
//  SizeCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 03/03/2022.
//

final class SizeCommand: Command {

    var instructions: Int {
        stateContext.memoryComponents.reduce(0) { $1.binary.dictionary
            .filter { $0.value.representsCompiled != nil }
            .count + $0 }
    }

    var bytes: Int {
        stateContext.memoryComponents.reduce(0) { $1.binary.size + $0 }
    }

    override func execute() {
        stateContext
            .preprocessor()
            .references()
            .transpile()

        CLIStateController.newline("Instruction blocks: \(stateContext.memoryComponents.count)")
        CLIStateController.newline("Instructions: \(instructions)")
        CLIStateController.newline("Total bytes: \(bytes)")
    }
}
