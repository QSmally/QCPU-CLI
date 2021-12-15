//
//  Deabstract.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

import Foundation

extension Transpiler {
    func prepare(helpers: [MemoryComponent]) {
        for statement in memoryComponent.file.removeCopy() {
            var instructionComponents = statement.components(separatedBy: .whitespaces)
            let master = instructionComponents.removeFirst()

            if let level = indentations.last {
                let isParsable = level.validate(master, tagComponents: instructionComponents)
                guard isParsable else { continue }
            }

            if Transpiler.compileTags.contains(master) {
                let indent = IndentationController(
                    identifier: master,
                    arguments: instructionComponents,
                    memoryComponent: memoryComponent)
                indentations.append(indent)
                continue
            }

            if let function = Expressions.function.match(statement, group: 1) {
                let functionController = FunctionController(
                    function,
                    from: statement,
                    memoryComponent: memoryComponent)
                memoryComponent.file += functionController.parse()
                continue
            }

            if let flag = Expressions.condition.match(statement, group: 1) {
                let parsedFlagBit = parseConditionFlag(flag, from: statement)
                let parsedStatement = statement.replacingOccurrences(of: "#\(flag)", with: parsedFlagBit)
                memoryComponent.file.append(parsedStatement)
                continue
            }

            if let tag = Expressions.marco.match(statement, group: 1) {
                let bytes = parseInsertableMarcos(tag, from: statement, helpers: helpers)
                memoryComponent.file += bytes
                continue
            }

            memoryComponent.file.append(statement)
        }
    }

    private func parseConditionFlag(_ flag: String, from statement: String) -> String {
        switch flag {
            case "true":      return "0"
            case "cout":      return "1"
            case "signed":    return "2"
            case "zero":      return "3"
            case "underflow": return "4"
            case "!cout":     return "5"
            case "!signed":   return "6"
            case "!zero":     return "7"
            default:
                CLIStateController.terminate("Parse error (\(memoryComponent.name)): invalid condition marco '\(flag)'")
        }
    }

    private func parseInsertableMarcos(_ tag: String, from statement: String, helpers: [MemoryComponent]) -> [String] {
        let headerComponent = helpers
            .first(where: { $0.header?.name == tag })?
            .clone()

        if let headerComponent = headerComponent {
            let arguments = statement
                .components(separatedBy: .whitespaces)
                .dropFirst()
            guard arguments.count >= headerComponent.header!.parameters.count else {
                CLIStateController.terminate("Parse error (\(memoryComponent.name)): signature of header '\(headerComponent.header!.name)' does not match caller")
            }

            for (index, name) in headerComponent.header!.parameters.enumerated() {
                let argument = name.starts(with: "*") ?
                    arguments[(index + 1)...].joined(separator: " ") :
                    arguments[index + 1]
                let replacedComponent = replaceSingleMarco(argument, helpers: helpers)
                headerComponent.transpiler.declare(name, value: replacedComponent)
            }

            headerComponent.transpiler.prepare(helpers: helpers)
            return headerComponent.file
        }

        if let marco = memoryComponent.declarations.first(where: { $0.key == tag }) {
            return [statement.replacingOccurrences(of: "@\(tag)", with: marco.value)]
        }

        let enumIdentifierComponents = tag.components(separatedBy: ".")

        if let namespace = enumIdentifierComponents.first,
           let enumCaseString = enumIdentifierComponents[optional: 1],
           let enumMemoryComponent = helpers.first(where: { $0.enumeration?.name == namespace }),
           let value = enumMemoryComponent.enumeration!.cases[enumCaseString] {
             return [statement.replacingOccurrences(of: "@\(tag)", with: value)]
        }

        CLIStateController.terminate("Parse error (\(memoryComponent.name)): unknown header, macro or enum '\(tag)'")
    }

    private func replaceSingleMarco(_ definiteComponent: String, helpers: [MemoryComponent]) -> String {
        if let tag = Expressions.marco.match(definiteComponent, group: 1) {
            if let marco = memoryComponent.declarations.first(where: { $0.key == tag }) {
                return definiteComponent.replacingOccurrences(of: "@\(tag)", with: marco.value)
            }

            let enumIdentifierComponents = tag.components(separatedBy: ".")

            if let namespace = enumIdentifierComponents.first,
               let enumCaseString = enumIdentifierComponents[optional: 1],
               let enumMemoryComponent = helpers.first(where: { $0.enumeration?.name == namespace }),
               let value = enumMemoryComponent.enumeration!.cases[enumCaseString] {
                return definiteComponent.replacingOccurrences(of: "@\(tag)", with: value)
            }

            CLIStateController.terminate("Parse error (\(memoryComponent.name)): unknown header, macro or enum '\(tag)'")
        } else {
            return definiteComponent
        }
    }
}
