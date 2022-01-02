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
                let randomString = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
                return [randomString]

            case "array":
                guard let arraySizeString = arguments[optional: 0],
                      let arraySize = Int(arraySizeString) else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): function 'array' requires an array size")
                }

                let repeatingUtf8 = arguments[optional: 1]?.utf8.first ?? 0
                return Array(repeating: String(repeatingUtf8), count: arraySize)

            default:
                CLIStateController.terminate("Parse error (\(memoryComponent.name)): invalid function '\(function)'")
        }
    }
}
