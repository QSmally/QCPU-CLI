//
//  CLICommandAttach.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 15/11/2021.
//

extension CLIStateController {

    var modules: [Command] {
        switch CLIStateController.arguments.first!.lowercased() {
            case "assemble": return [AssemblerCommand(controller: self)]
            default: return []
        }
    }

    func handleCommandInput() {
        if modules.count > 0 {
            let stateContext = StateContext(controller: self)
            modules.forEach { $0.execute(with: stateContext) }
            return
        }

        let inputCommand = CLIStateController.arguments.first!
        CLIStateController.newline("Error: invalid command '\(inputCommand)'")
    }
}
