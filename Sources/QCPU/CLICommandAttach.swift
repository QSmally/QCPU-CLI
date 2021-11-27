//
//  CLICommandAttach.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 15/11/2021.
//

extension CLIStateController {

    var module: Command? {
        switch CLIStateController.arguments.first!.lowercased() {
            case "assemble": return AssemblerCommand(controller: self)
            default:
                return nil
        }
    }

    func handleCommandInput() {
        if let module = module {
            let stateContext = StateContext(controller: self)
            module.execute(with: stateContext)
            return
        }

        let inputCommand = CLIStateController.arguments.first!
        CLIStateController.newline("Error: invalid command '\(inputCommand)'")
    }
}
