//
//  Tags.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/01/2022.
//

extension Transpiler {
    func applyTag(_ tag: String, arguments: [String]) {
        switch tag {
            case "@PAGE":
                guard let upperMemoryString = arguments[optional: 0],
                      let lowerMemoryString = arguments[optional: 1] else {
                    CLIStateController.terminate("Parse error: missing segment and/or page address")
                }

                guard let upperMemoryAddress = Int(upperMemoryString),
                      let lowerMemoryAddress = Int(lowerMemoryString) else {
                    CLIStateController.terminate("Parse error: couldn't parse addressing as integers")
                }

                memoryComponent.address = MemoryComponent.Address(
                    segment: upperMemoryAddress,
                    page: lowerMemoryAddress)

            case "@HEADER":
                guard let label = arguments[optional: 0] else {
                    CLIStateController.terminate("Parse error: missing header label")
                }

                let parameters = Array(arguments.dropFirst())
                parameters.forEach { Expressions.stylingGuideline(forDeclaration: $0) }
                Expressions.stylingGuideline(forHeader: label)

                memoryComponent.header = (
                    name: label,
                    parameters: parameters)

            case "@ADDRESSABLE":
                guard let namespace = arguments[optional: 0] else {
                    CLIStateController.terminate("Parse error: missing callable namespace")
                }

                Expressions.stylingGuideline(forDeclaration: namespace)
                memoryComponent.namespaceCallable = namespace

            case "@OVERFLOWABLE":
                memoryComponent.overflowable = true

            case "@MAKEPAGE":
                guard let name = arguments[optional: 0],
                      let upperMemoryString = arguments[optional: 1],
                      let lowerMemoryString = arguments[optional: 2] else {
                    CLIStateController.terminate("Parse error: missing page name and/or addressing")
                }

                guard let upperMemoryAddress = Int(upperMemoryString),
                      let lowerMemoryAddress = Int(lowerMemoryString) else {
                    CLIStateController.terminate("Parse error: couldn't parse addressing as integers")
                }

                let address = MemoryComponent.Address(
                    segment: upperMemoryAddress,
                    page: lowerMemoryAddress)

                let pageComponent = MemoryComponent.empty(name, atAddress: address)
                pageComponent.purpose = .reserved

                pagesGenerated.append(pageComponent)

            case "@DECLARE":
                guard let tag = arguments[optional: 0],
                      let value = arguments[optional: 1] else {
                    CLIStateController.terminate("Parse error: missing tag and/or value for declaration")
                }

                Expressions.stylingGuideline(forDeclaration: tag)
                declare(tag, value: value)

            case "@ENUM":
                let layer = IndentationLayer.create(
                    fromString: arguments
                        .inserted(tag, at: 0)
                        .joined(separator: " "),
                    memoryComponent: memoryComponent)
                layers.append(layer)

            default:
                CLIStateController.newline("Parse warning: unhandled tag '\(tag)'")
        }
    }

    func declare(_ key: String, value: String) {
        var preprocessedString = value

        if let function = Expressions.function.match(value, group: 1) {
            let parsedStatements = FunctionController
                .create(function)
                .parse()
            preprocessedString = parsedStatements.first ?? value
        }

        if layers.last?.instruction == "@ENUM",
           let namespace = layers.last?.arguments.first {
            memoryComponent.enums[namespace]?[key] = preprocessedString
        } else {
            memoryComponent.declarations[key] = preprocessedString
        }
    }
}
