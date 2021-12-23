//
//  IndentationController.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 22/11/2021.
//

class IndentationController {

    let identifier: String
    let arguments: [String]

    unowned var memoryComponent: MemoryComponent

    var processCache = [String: Bool]()

    init(identifier: String,
         arguments: [String],
         memoryComponent: MemoryComponent) {
        self.identifier = identifier
        self.arguments = arguments
        self.memoryComponent = memoryComponent

        switch identifier {
            case "@IF":
                guard let flagString = arguments[optional: 0] else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): missing conditional statement")
                }

                if let flag = Expressions.flag.match(flagString, group: 2),
                   let inverse = Expressions.flag.match(flagString, group: 1) {
                    var result = CLIStateController.flags.contains(flag)
                    if inverse == "!" { result.toggle() }
                    processCache["if-pass"] = result
                }

            case "@ENUM":
                guard let namespace = arguments[optional: 0] else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): missing enum namespace")
                }

                StylingGuidelines.validate(namespace, withSource: .declaration)
                memoryComponent.enumeration = (name: namespace, cases: [:])

            default:
                break
        }
    }

    @discardableResult
    func validate(_ anyStatement: String, tagComponents: [String], mutableStatement: inout String) -> Bool {
        if anyStatement == "@END" {
            memoryComponent.transpiler.indentations.removeLast()
            return false
        }

        switch identifier {
            case "@IF":
                if anyStatement == "@ELSE" {
                    processCache["if-pass"]?.toggle()
                    return false
                }

                if anyStatement == "@DROPTHROUGH" {
                    mutableStatement = mutableStatement
                        .components(separatedBy: .whitespaces)
                        .dropFirst()
                        .joined(separator: " ")
                    return true
                }

                return processCache["if-pass"] ?? false

            case "@ENUM":
                anyStatement == "@DECLARE" ?
                    memoryComponent.transpiler.parseTag(anyStatement, tagComponents: tagComponents) :
                    CLIStateController.newline("Parse warning (\(memoryComponent.name)): an enum may only contain '@DECLARE' statements")
                return false

            default:
                CLIStateController.terminate("Parse error (\(memoryComponent.name)): invalid indentation tag '\(identifier)'")
        }
    }
}
