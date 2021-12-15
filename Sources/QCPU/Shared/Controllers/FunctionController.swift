//
//  FunctionController.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

import Foundation

class FunctionController {

    let function: String
    let arguments: [String]
    let statement: String

    unowned var memoryComponent: MemoryComponent

    init(_ function: String, from statement: String, memoryComponent: MemoryComponent) {
        var components = function.components(separatedBy: .whitespaces)
        self.function = components.removeFirst()
        self.arguments = components
        self.statement = statement
        self.memoryComponent = memoryComponent
    }

    func parse() -> [String] {
        switch function {
            case "random":
                return [UUID().uuidString.replacingOccurrences(of: "-", with: "_")]

            case "array":
                return []

            default:
                CLIStateController.terminate("Parse error (\(memoryComponent.name)): invalid function '\(function)'")
        }
    }
}
