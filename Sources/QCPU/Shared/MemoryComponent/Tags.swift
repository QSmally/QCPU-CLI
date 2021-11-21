//
//  Tags.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 20/11/2021.
//

struct IndentationLevel {

    let identifier: String
    let arguments: [String]
    unowned var memoryComponent: MemoryComponent

    func validate(_ anyStatement: String, tagComponents: [String]) {
        if anyStatement == "@END" {
            memoryComponent.indentations.removeLast()
            return
        }

        switch identifier {
            case "@IF":
                CLIStateController.newline("Parse warning: if-statements aren't supported at this time")
            case "@ENUM":
                anyStatement == "@DECLARE" ?
                    memoryComponent.parseTag(anyStatement, tagComponents: tagComponents) :
                    CLIStateController.newline("Parse warning (\(memoryComponent.name)): an enum may only contain '@DECLARE' statements")
            default:
                CLIStateController.terminate("Parse error (\(memoryComponent.name)): invalid indentation tag '\(identifier)'")
        }
    }
}

extension MemoryComponent {
    func tags() {
        for tag in file.prefix(while: { $0.hasPrefix("@") }) {
            var tagComponents = tag.components(separatedBy: .whitespaces)
            let identifier = tagComponents.removeFirst()

            if indentations.count > 0 {
                indentations.last!.validate(identifier, tagComponents: tagComponents)
                continue
            }

            if MemoryComponent.validTags.contains(identifier) {
                parseTag(identifier, tagComponents: tagComponents)
                tagAmount += 1
                continue
            }

            CLIStateController.terminate("Parse error (\(name)): invalid tag '\(identifier)'")
        }

        file.removeFirst(tagAmount)
    }

    fileprivate func parseTag(_ tag: String, tagComponents: [String]) {
        switch tag {
            case "@IF",
                "@ENUM":
                let indent = IndentationLevel(
                    identifier: tag,
                    arguments: tagComponents,
                    memoryComponent: self)
                indentations.append(indent)
            default:
                CLIStateController.newline("Parse warning (\(name)): unhandled tag '\(tag)'")
        }
    }
}
