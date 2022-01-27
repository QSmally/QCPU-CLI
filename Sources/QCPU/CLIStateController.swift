//
//  CLIStateController.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 15/11/2021.
//

import Foundation

final class CLIStateController {

    static let arguments = CommandLine.arguments.dropFirst()
    static let flags = arguments
        .filter { $0.starts(with: "--") }
        .map { String($0.dropFirst(2)) }

    static let help = [
        "USAGE:",
        "  qcpu <command> <arguments>\n",
        "COMMANDS:",
        "  preprocess <path>               processes macros and outputs assembly with only labels.",
        "  assemble <path>                 converts extended QCPU assembly into machine language.",
        "  documentate <path> <dest?>      generates markdown documentation from the assembly tags.",
        "  emulate <path> <clock speed?>   executes QCPU machine code.",
        "  run <path> <clock speed?>       assembles and emulates extended QCPU assembly.\n",
        "ARGUMENTS:",
        "  clock speed   an interval in hertz",
    ].byNewlines()

    var module: Command? {
        let stateContext = StateContext(controller: self)
        switch CLIStateController.arguments.first!.lowercased() {
            case "preprocess":  return PreprocessCommand(stateContext: stateContext)
            case "assemble":    return AssemblerCommand(stateContext: stateContext)
            case "documentate": return DocumentationCommand(stateContext: stateContext)
            case "run":         return RunCommand(stateContext: stateContext)
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
        guard let module = module else {
            let inputCommand = CLIStateController.arguments.first!
            CLIStateController.terminate("Error: invalid command '\(inputCommand)'")
        }

        module.execute()
    }
}
