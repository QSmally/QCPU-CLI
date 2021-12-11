//
//  Tags.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 20/11/2021.
//

extension Transpiler {
    func tags() -> MemoryComponent {
        for tag in memoryComponent.file {
            var tagComponents = tag.components(separatedBy: .whitespaces)
            let identifier = tagComponents.removeFirst()

            if !tag.starts(with: "@") &&
                indentations.count == 0 ||
                Transpiler.breakTaglike.contains(identifier) { break }
            tagAmount += 1

            if let level = indentations.last {
                level.validate(identifier, tagComponents: tagComponents)
                continue
            }

            if Transpiler.validTags.contains(identifier) {
                parseTag(identifier, tagComponents: tagComponents)
                continue
            }

            CLIStateController.terminate("Parse error (\(memoryComponent.name)): invalid tag '\(identifier)'")
        }

        memoryComponent.file.removeFirst(tagAmount)
        return memoryComponent
    }

    func declare(_ key: String, value: String) {
        var sanitisedString = value

        if let function = Expressions.function.match(value, group: 1) {
            let functionController = FunctionController(
                function,
                from: value,
                memoryComponent: memoryComponent)
            sanitisedString = functionController.parse().first ?? value
        }

        if indentations.last?.identifier == "@ENUM" {
            memoryComponent.enumeration!.cases[key] = sanitisedString
        } else {
            memoryComponent.declarations[key] = sanitisedString
        }
    }

    func parseTag(_ tag: String, tagComponents: [String]) {
        switch tag {
            case "@PAGE":
                guard let upperMemoryString = tagComponents[optional: 0],
                      let lowerMemoryString = tagComponents[optional: 1] else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): missing address segment and/or page")
                }

                guard let upperMemoryAddress = Int(upperMemoryString),
                      let lowerMemoryAddress = Int(lowerMemoryString) else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): couldn't parse addressing as integers")
                }

                memoryComponent.address = MemoryComponent.Address(segment: upperMemoryAddress, page: lowerMemoryAddress)

            case "@HEADER":
                guard let label = tagComponents[optional: 0] else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): missing header label")
                }

                let parameters = Array(tagComponents.dropFirst())
                parameters.forEach { StylingGuidelines.validate($0, withSource: .declaration) }
                StylingGuidelines.validate(label, withSource: .header)

                memoryComponent.header = (name: label, parameters: parameters)

            case "@ADDRESSABLE":
                guard let namespace = tagComponents[optional: 0] else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): missing callable namespace")
                }

                StylingGuidelines.validate(namespace, withSource: .declaration)
                memoryComponent.namespaceCallable = namespace

            case "@OVERFLOWABLE":
                memoryComponent.overflowable = true

            case "@DECLARE":
                guard let tag = tagComponents[optional: 0],
                      let value = tagComponents[optional: 1] else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): missing tag and/or value for declaration")
                }

                StylingGuidelines.validate(tag, withSource: .declaration)
                declare(tag, value: value)

            case "@ENUM":
                let indent = IndentationController(
                    identifier: tag,
                    arguments: tagComponents,
                    memoryComponent: memoryComponent)
                indentations.append(indent)

            default:
                CLIStateController.newline("Parse warning (\(memoryComponent.name)): unhandled tag '\(tag)'")
        }
    }
}
