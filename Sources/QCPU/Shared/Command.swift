//
//  Command.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

class Command {

    unowned var controller: CLIStateController

    init(controller: CLIStateController) {
        self.controller = controller
    }

    func execute(with stateContext: StateContext) {
        
    }
}
