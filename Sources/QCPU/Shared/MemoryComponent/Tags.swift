//
//  Tags.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 20/11/2021.
//

extension MemoryComponent {
    func tags() -> MemoryComponent {
        for tag in file {
            var tagComponents = tag.components(separatedBy: .whitespaces)
            let identifier = tagComponents.removeFirst()

            if !tag.hasPrefix("@") &&
                indentations.count == 0 ||
                MemoryComponent.breakTaglike.contains(identifier) { break }
            tagAmount += 1

            if indentations.count > 0 {
                indentations.last!.validate(identifier, tagComponents: tagComponents)
                continue
            }

            if MemoryComponent.validTags.contains(identifier) {
                parseTag(identifier, tagComponents: tagComponents)
                continue
            }

            CLIStateController.terminate("Parse error (\(name)): invalid tag '\(identifier)'")
        }

        file.removeFirst(tagAmount)
        return self
    }

    internal func parseTag(_ tag: String, tagComponents: [String]) {
        switch tag {
            case "@PAGE":
                guard let upperMemoryString = tagComponents[optional: 0],
                      let lowerMemoryString = tagComponents[optional: 1] else {
                    CLIStateController.terminate("Parse error (\(name)): missing address segment and/or page")
                }

                guard let upperMemoryAddress = UInt(upperMemoryString),
                      let lowerMemoryAddress = UInt(lowerMemoryString) else {
                    CLIStateController.terminate("Parse error (\(name)): couldn't parse addressing as unsigned integers")
                }

                address = (upperMemoryAddress, lowerMemoryAddress)

            case "@HEADER":
                guard let label = tagComponents[optional: 0] else {
                    CLIStateController.terminate("Parse error (\(name)): missing header label")
                }

                header = (
                    name: label,
                    parameters: Array(tagComponents.dropFirst()))

            case "@ADDRESSABLE":
                guard let namespace = tagComponents[optional: 0] else {
                    CLIStateController.terminate("Parse error (\(name)): missing callable namespace")
                }

                namespaceCallable = namespace

            case "@OVERFLOWABLE":
                overflowable = true

            case "@DECLARE":
                guard let tag = tagComponents[optional: 0],
                      let value = tagComponents[optional: 1] else {
                    CLIStateController.terminate("Parse error (\(name)): missing tag and/or value for declaration")
                }

                if indentations.last?.identifier == "@ENUM",
                   var enumeration = enumeration {
                    enumeration.cases[tag] = value
                } else {
                    declarations[tag] = value
                }

            case "@ENUM":
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
