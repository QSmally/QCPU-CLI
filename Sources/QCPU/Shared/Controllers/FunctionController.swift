//
//  FunctionController.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

import Foundation

class FunctionController {

    var line: String

    lazy var function: String = {
        var components = line.components(separatedBy: .whitespaces)
        return components.removeFirst()
    }()

    lazy var arguments: [String] = {
        let arraySlice = line
            .components(separatedBy: .whitespaces)
            .dropFirst()
        return Array(arraySlice)
    }()

    init(line: String) {
        self.line = line
    }

    static func create(_ line: String) -> FunctionController {
        FunctionController(line: line)
    }

    func parse() -> [String] {
        switch function {
            case "random":
                let randomString = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
                return [randomString]

            case "array":
                guard let arraySizeString = arguments[optional: 0],
                      let arraySize = Int(arraySizeString) else {
                    CLIStateController.terminate("Parse error: function 'array' requires an array size")
                }

                let repeatingUtf8 = arguments[optional: 1]?.utf8.first ?? 0
                return Array(
                    repeating: String(repeatingUtf8),
                    count: arraySize)

            default:
                CLIStateController.terminate("Parse error: invalid function '\(function)'")
        }
    }
}
