//
//  CLIStateController.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 15/11/2021.
//

import Foundation

final class CLIStateController {

    static let arguments = CommandLine.arguments.dropFirst()

    let help = [
        "USAGE:",
        "  qcpu <command> <arguments>\n",
        "COMMANDS:",
        "  assemble <path>                 converts extended QCPU 2 assembly into machine language.",
        "  emulate <path> <clock speed?>   executes QCPU 2 machine code.",
        "  run <path> <clock speed?>       assembles and emulates extended QCPU 2 assembly."
    ].byNewlines()

    init() {
        CLIStateController.arguments.count > 0 ?
            self.handleCommandInput() :
            CLIStateController.newline(self.help)
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
}
