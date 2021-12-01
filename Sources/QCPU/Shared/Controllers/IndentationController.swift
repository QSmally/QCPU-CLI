//
//  IndentationController.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 22/11/2021.
//

struct IndentationController {

    let identifier: String
    let arguments: [String]
    unowned var memoryComponent: MemoryComponent

    init(identifier: String,
         arguments: [String],
         memoryComponent: MemoryComponent) {
        self.identifier = identifier
        self.arguments = arguments
        self.memoryComponent = memoryComponent

        switch identifier {
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
    func validate(_ anyStatement: String, tagComponents: [String]) -> Bool {
        if anyStatement == "@END" {
            memoryComponent.transpiler.indentations.removeLast()
            return false
        }

        switch identifier {
            case "@IF":
                // TODO:
                // Implement parsing of the condition and return true if the instruction can
                // be used to propagate the parser.
                return true

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
