//
//  IndentationLevel.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 22/11/2021.
//

struct IndentationLevel {

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
                memoryComponent.enumeration = (name: namespace, cases: [:])
            default:
                break
        }
    }

    func validate(_ anyStatement: String, tagComponents: [String]) {
        if anyStatement == "@END" {
            memoryComponent.indentations.removeLast()
            return
        }

        switch identifier {
            case "@ENUM":
                anyStatement == "@DECLARE" ?
                memoryComponent.parseTag(anyStatement, tagComponents: tagComponents) :
                CLIStateController.newline("Parse warning (\(memoryComponent.name)): an enum may only contain '@DECLARE' statements")
            default:
                CLIStateController.terminate("Parse error (\(memoryComponent.name)): invalid indentation tag '\(identifier)'")
        }
    }
}
