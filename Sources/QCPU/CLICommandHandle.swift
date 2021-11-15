//
//  CLIStateHandle.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 15/11/2021.
//

extension CLIStateController {
    func handleCommandInput() {
        let command = CLIStateController.arguments.first!
        CLIStateController.newline(command)
    }
}
