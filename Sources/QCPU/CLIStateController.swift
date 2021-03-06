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
        "  prebuild <path>                                  processes macros and outputs assembly with only labels.",
        "  assemble <path>                                  converts extended QCPU assembly into machine language.",
        "  documentate <path> --dest=path                   generates markdown documentation from the assembly tags.",
        "  run <path> --clock=int --burst=int --time=int    assembles and emulates (extended) QCPU assembly.",
        "  coverage <path>                                  returns a detailed view of the segment/page code coverage.",
        "  size <path>                                      returns the size of the application.\n",
        "ARGUMENTS:",
        "  dest     a destination path.",
        "  clock    an interval in hertz.",
        "  burst    a burst size of instructions to emulate.",
        "  time     milliseconds to spend on emulating before terminating."
    ].byNewlines()

    var module: Command? {
        let stateContext = StateContext(controller: self)
        switch CLIStateController.arguments.first!.lowercased() {
            case "prebuild":    return PrebuildCommand(stateContext: stateContext)
            case "assemble":    return AssemblerCommand(stateContext: stateContext)
            case "documentate": return DocumentationCommand(stateContext: stateContext)
            case "run":         return RunCommand(stateContext: stateContext)
            case "coverage":    return CoverageCommand(stateContext: stateContext)
            case "size":        return SizeCommand(stateContext: stateContext)
            default:
                return nil
        }
    }

    static func output(_ text: String) {
        let encodedText = text.data(using: .utf8)!
        try! FileHandle.standardOutput.write(contentsOf: encodedText)
    }

    static func newline(_ text: String) {
        CLIStateController.output(text.appending("\n"))
    }

    static func terminate(_ message: String? = nil) -> Never {
        if let message = message {
            CLIStateController.newline(message)
        }
        exit(0)
    }

    static func argument(withId prefix: String) -> String? {
        let identifier = "--\(prefix)="
        var firstMatchingArgument = arguments
            .filter { $0.starts(with: identifier) }
            .first
        firstMatchingArgument?.removeFirst(identifier.count)

        return firstMatchingArgument
    }

    static func flag(withId prefix: String) -> Bool {
        arguments.contains("--\(prefix)")
    }
}
