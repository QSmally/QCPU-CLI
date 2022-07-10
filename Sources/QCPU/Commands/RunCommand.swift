//
//  RunCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

final class RunCommand: Command {

    lazy var speed: Double? = {
        let clockSpeed = CLIStateController.argument(withId: "clock")
        return clockSpeed != nil ?
            Double(clockSpeed ?? "5") :
            stateContext.defaults.speed
    }()

    lazy var burstSize: Int = {
        let burstSize = CLIStateController.argument(withId: "burst")
        return Int(burstSize ?? "4096") ??
            stateContext.defaults.burstSize ??
            4096
    }()

    override func execute() {
        stateContext
            .preprocessor()
            .references()
            .transpile()

        EmulatorStateController(defaults: stateContext.defaults, memoryComponents: stateContext.memoryComponents)
            .startClockTimer(withSpeed: speed, burstSize: burstSize)
    }
}
