//
//  RunCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

final class RunCommand: Command {

    lazy var speed = CLIStateController.arguments.count >= 3 ?
        Double(CLIStateController.arguments[3]) :
        stateContext.defaults.speed ?? 5

    override func execute() {
        stateContext
            .preprocessor()
            .references()
            .transpile()

        EmulatorStateController(defaults: stateContext.defaults, memoryComponents: stateContext.memoryComponents)
            .startClockTimer(withSpeed: speed, burstSize: 4096)
    }
}
