//
//  IndentationLayer.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 22/11/2021.
//

class IndentationLayer {

    var line: String
    unowned var memoryComponent: MemoryComponent

    var stateCache = [String: Bool]()

    lazy var instruction: String = {
        var components = line.components(separatedBy: .whitespaces)
        return components.removeFirst()
    }()

    lazy var arguments: [String] = {
        let arraySlice = line
            .components(separatedBy: .whitespaces)
            .dropFirst()
        return Array(arraySlice)
    }()

    init(line: String, memoryComponent: MemoryComponent) {
        self.line = line
        self.memoryComponent = memoryComponent
    }

    static func create(fromString line: String, memoryComponent: MemoryComponent) -> IndentationLayer {
        let layer = IndentationLayer(
            line: line,
            memoryComponent: memoryComponent)

        switch layer.instruction {
            case "@IF":
                guard let flagString = layer.arguments[optional: 0] else {
                    CLIStateController.terminate("Parse error: missing conditional statement")
                }

                if let flag = Expressions.flag.match(flagString, group: 2),
                   let inverse = Expressions.flag.match(flagString, group: 1) {
                    var result = CLIStateController.flags.contains(flag)
                    if inverse == "!" { result.toggle() }
                    layer.stateCache["if-pass"] = result
                }

            case "@ENUM":
                guard let namespace = layer.arguments[optional: 0] else {
                    CLIStateController.terminate("Parse error: missing enum namespace")
                }

                Expressions.stylingGuideline(forDeclaration: namespace)
                memoryComponent.enumeration = (
                    name: namespace,
                    cases: [:])

            default:
                break
        }

        return layer
    }

    @discardableResult func handle(statement: inout String) -> Bool {
        var lineComponents = statement.components(separatedBy: .whitespaces)
        let firstTagElement = lineComponents.removeFirst()

        if firstTagElement == "@END" {
            memoryComponent.transpiler.layers.removeLast()
            return false
        }

        switch instruction {
            case "@IF":
                if firstTagElement == "@ELSE" {
                    stateCache["if-pass"]?.toggle()
                    return false
                }

                if firstTagElement == "@DROPTHROUGH" {
                    statement = statement
                        .components(separatedBy: .whitespaces)
                        .dropFirst()
                        .joined(separator: " ")
                    return true
                }

                return stateCache["if-pass"] ?? false

            case "@ENUM":
                firstTagElement == "@DECLARE" ?
                    memoryComponent.transpiler.applyTag(firstTagElement, arguments: lineComponents) :
                    CLIStateController.newline("Parse warning: an enum may only contain '@DECLARE' statements")
                return false

            default:
                CLIStateController.terminate("Parse error: invalid indentation tag '\(instruction)'")
        }
    }
}
