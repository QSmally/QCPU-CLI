//
//  CLIStateController.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 15/11/2021.
//

import Foundation

final class CLIStateController {

    static let arguments = CommandLine.arguments.dropFirst()

    static let help = [
        "USAGE:",
        "  qcpu <command> <arguments>\n",
        "COMMANDS:",
        "  assemble <path>                 converts extended QCPU assembly into machine language.",
        "  documentate <path> <dest?>      generates markdown documentation from the assembly tags.",
        "  emulate <path> <clock speed?>   executes QCPU machine code.",
        "  run <path> <clock speed?>       assembles and emulates extended QCPU assembly.\n",
        "ARGUMENTS:",
        "  clock speed   an interval in hertz",
    ].byNewlines()

    var module: Command? {
        switch CLIStateController.arguments.first!.lowercased() {
            case "assemble":    return AssemblerCommand(controller: self)
            case "documentate": return DocumentationCommand(controller: self)
            default:
                return nil
        }
    }

    init() {
        CLIStateController.arguments.count > 0 ?
            handleCommandInput() :
            CLIStateController.newline(CLIStateController.help)
    }

    static func output(_ text: String) {
        let encodedText = text.data(using: .utf8)!
        try! FileHandle.standardOutput.write(contentsOf: encodedText)
    }

    static func newline(_ text: String) {
        CLIStateController.output(text.appending("\n"))
    }

    static func clear() {
        CLIStateController.output("\u{1B}[2J")
        CLIStateController.output("\u{1B}[1;1H")
    }

    static func terminate(_ message: String? = nil) -> Never {
        if let message = message {
            CLIStateController.newline(message)
        }
        exit(0)
    }
    
    func handleCommandInput() {
        if let module = module {
            let stateContext = StateContext(controller: self)
            module.execute(with: stateContext)
            return
        }

        let inputCommand = CLIStateController.arguments.first!
        CLIStateController.terminate("Error: invalid command '\(inputCommand)'")
    }
}
