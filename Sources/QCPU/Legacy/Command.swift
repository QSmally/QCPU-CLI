//
//  Command.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

class Command {

    var stateContext: StateContext

    init(stateContext: StateContext) {
        self.stateContext = stateContext
    }

    func execute() {
        CLIStateController.terminate("Fatal error: command not implemented")
    }
}
