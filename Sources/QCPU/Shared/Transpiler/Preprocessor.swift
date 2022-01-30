//
//  Preprocessor.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 20/11/2021.
//

extension Transpiler {
    func parseTags() -> MemoryComponent {
        for line in memoryComponent.representativeStrings {
            var lineString = line
            var lineComponents = lineString.components(separatedBy: .whitespaces)
            let firstTagElement = lineComponents.removeFirst()

            if !lineString.starts(with: "@") &&
                layers.isEmpty ||
                Transpiler.breakTaglike.contains(firstTagElement) { break }
            tagAmount += 1

            if let layer = layers.last {
                layer.handle(statement: &lineString)
                continue
            }

            if Transpiler.validTags.contains(firstTagElement) {
                applyTag(firstTagElement, arguments: lineComponents)
                continue
            }

            CLIStateController.terminate("Parse error: invalid tag '\(firstTagElement)'")
        }

        memoryComponent.representativeStrings.removeFirst(tagAmount)
        return memoryComponent
    }

    func preprocessor(withComponents memoryComponents: [MemoryComponent]) {
        for line in memoryComponent.representativeStrings.removeCopyEnumerated() {
            var lineString = line
            var instructionComponents = lineString.components(separatedBy: .whitespaces)
            let operation = instructionComponents.removeFirst()

            if let layer = layers.last {
                guard layer.handle(statement: &lineString) else {
                    continue
                }
            }

            if Transpiler.compileTags.contains(operation) {
                let indentation = IndentationLayer.create(
                    fromString: lineString,
                    memoryComponent: memoryComponent)
                layers.append(indentation)
                continue
            }

            if let function = Expressions.function.match(lineString, group: 1) {
                let parsedStatements = FunctionController
                    .create(function)
                    .parse()
                memoryComponent.representativeStrings.append(contentsOf: parsedStatements)
                continue
            }

            if let flag = Expressions.condition.match(lineString, group: 1) {
                let parsedFlagOperand = parseConditionFlag(flag)
                let parsedStatement = lineString.replacingOccurrences(of: "#\(flag)", with: parsedFlagOperand)
                memoryComponent.representativeStrings.append(parsedStatement)
                continue
            }

            if let tag = Expressions.marco.match(lineString, group: 1) {
                let instructions = parsePreprocessorMarcos(
                    tag,
                    statement: lineString,
                    memoryComponents: memoryComponents)
                memoryComponent.representativeStrings.append(contentsOf: instructions)
                continue
            }

            memoryComponent.representativeStrings.append(lineString)
        }
    }

    private func parseConditionFlag(_ flag: String) -> String {
        switch flag {
            case "cout":       return "0"
            case "signed":     return "1"
            case "zero":       return "2"
            case "underflow":  return "3"
            case "!cout":      return "4"
            case "!signed":    return "5"
            case "!zero":      return "6"
            case "!underflow": return "7"
            default:
                CLIStateController.terminate("Parse error: invalid condition macro '\(flag)'")
        }
    }

    private func parsePreprocessorMarcos(_ tag: String, statement: String, memoryComponents: [MemoryComponent]) -> [String] {
        // Header
        let headerComponent = memoryComponents
            .first { $0.header?.name == tag }?
            .clone()

        if let headerComponent = headerComponent,
           let header = headerComponent.header {
            let arguments = statement
                .components(separatedBy: .whitespaces)
                .dropFirst()
            guard arguments.count >= header.parameters.count else {
                CLIStateController.terminate("Parse error: signature of header '\(header.name)' does not match caller")
            }

            for (index, name) in header.parameters.enumerated() {
                let argument = name.hasSuffix("...") ?
                    arguments[(index + 1)...].joined(separator: " ") :
                    arguments[index + 1]
                let macro = replaceSingleMacro(argument, memoryComponents: memoryComponents)
                headerComponent.transpiler.declare(name, value: macro)
            }

            headerComponent.transpiler.preprocessor(withComponents: memoryComponents)
            return headerComponent.representativeStrings
        }

        // Single macro
        return [replaceSingleMacro(tag, memoryComponents: memoryComponents)]
    }

    private func replaceSingleMacro(_ definitiveString: String, memoryComponents: [MemoryComponent]) -> String {
        if let tag = Expressions.marco.match(definitiveString, group: 1) {
            if let marco = memoryComponent.declarations.first(where: { $0.key == tag }) {
                return definitiveString.replacingOccurrences(of: "@\(tag)", with: marco.value)
            }

            let enumComponents = tag.components(separatedBy: ".")

            if let namespace = enumComponents.first,
               let enumCaseString = enumComponents[optional: 1],
               let enumMemoryComponent = memoryComponents.first(where: { $0.enumeration?.name == namespace }),
               let value = enumMemoryComponent.enumeration!.cases[enumCaseString] {
                return definitiveString.replacingOccurrences(of: "@\(tag)", with: value)
            }

            CLIStateController.terminate("Parse error: unknown header, macro or enum '\(tag)'")
        } else {
            return definitiveString
        }
    }
}
