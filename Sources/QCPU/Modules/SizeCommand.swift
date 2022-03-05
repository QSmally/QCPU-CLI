//
//  SizeCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 03/03/2022.
//

final class SizeCommand: Command {

    var bytes: Int {
        stateContext.memoryComponents.reduce(0) { $1.binary.size }
    }

    var instructions: Int {
        stateContext.memoryComponents.reduce(0) { $1.binary.dictionary
            .filter { $0.value.representsCompiled != nil }
            .count }
    }

    override func execute() {
        stateContext
            .preprocessor()
            .references()
            .transpile()

        CLIStateController.newline("Memory blocks: \(stateContext.memoryComponents.count)")
        CLIStateController.newline("Bytes: \(bytes)")
        CLIStateController.newline("Instructions: \(instructions)")
    }
}
