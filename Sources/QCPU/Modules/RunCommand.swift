//
//  RunCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

final class RunCommand: Command {

    lazy var speed = CLIStateController.arguments.count >= 3 ?
        Double(CLIStateController.arguments[3]) ?? 5 :
        5

    override func execute() {
        stateContext
            .preprocessor()
            .references()
            .transpile()

        EmulatorStateController(memoryComponents: stateContext.memoryComponents)
            .startClockTimer(withSpeed: speed)
    }
}
