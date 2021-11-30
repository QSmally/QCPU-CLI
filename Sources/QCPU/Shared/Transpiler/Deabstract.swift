//
//  Deabstract.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

import Foundation

extension MemoryComponent {

    static var compileTags: [String] {
        MemoryComponent.breakTaglike + ["@END"]
    }

    func prepare(helpers: [MemoryComponent]) {
        for statement in file.removeCopy() {
            var instructionComponents = statement.components(separatedBy: .whitespaces)
            let master = instructionComponents.removeFirst()

            if let level = indentations.last {
                let isParsable = level.validate(master, tagComponents: instructionComponents)
                guard isParsable else { continue }
            }

            if MemoryComponent.compileTags.contains(master) {
                let indent = IndentationController(
                    identifier: master,
                    arguments: instructionComponents,
                    memoryComponent: self)
                indentations.append(indent)
                continue
            }

            if let function = Expressions.function.match(statement, group: 1) {
                let functionController = FunctionController(
                    function,
                    from: statement,
                    memoryComponent: self)
                file += functionController.parse()
                continue
            }

            if let flag = Expressions.flag.match(statement, group: 1) {
                let parsedFlagBit = parseConditionFlag(flag, from: statement)
                let parsedStatement = statement.replacingOccurrences(of: "#\(flag)", with: parsedFlagBit)
                file.append(parsedStatement)
                continue
            }

            if let tag = Expressions.tag.match(statement, group: 1) {
                let bytes = parseInsertableMarcos(tag, from: statement, helpers: helpers)
                file += bytes
                continue
            }

            file.append(statement)
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
                CLIStateController.terminate("Parse error (\(name)): invalid condition marco '\(flag)'")
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
            guard headerComponent.header!.parameters.count == arguments.count else {
                CLIStateController.terminate("Parse error (\(name)): signature of header '\(headerComponent.header!.name)' does not match caller")
            }

            for (index, name) in headerComponent.header!.parameters.enumerated() {
                let argumentComponent = replaceSingleMarco(arguments[index + 1], helpers: helpers)
                headerComponent.declare(name, value: argumentComponent)
            }

            headerComponent.prepare(helpers: helpers)
            return headerComponent.file
        }

        if let marco = declarations.first(where: { $0.key == tag }) {
            return [statement.replacingOccurrences(of: "@\(tag)", with: marco.value)]
        }

        let enumIdentifierComponents = tag.components(separatedBy: ".")

        if let namespace = enumIdentifierComponents.first,
           let enumCaseString = enumIdentifierComponents[optional: 1],
           let enumMemoryComponent = helpers.first(where: { $0.enumeration?.name == namespace }),
           let value = enumMemoryComponent.enumeration!.cases[enumCaseString] {
             return [statement.replacingOccurrences(of: "@\(tag)", with: value)]
        }

        CLIStateController.terminate("Parse error (\(name)): unknown header, macro or enum '\(tag)'")
    }

    private func replaceSingleMarco(_ definiteComponent: String, helpers: [MemoryComponent]) -> String {
        if let tag = Expressions.tag.match(definiteComponent, group: 1) {
            if let marco = declarations.first(where: { $0.key == tag }) {
                return definiteComponent.replacingOccurrences(of: "@\(tag)", with: marco.value)
            }

            let enumIdentifierComponents = tag.components(separatedBy: ".")

            if let namespace = enumIdentifierComponents.first,
               let enumCaseString = enumIdentifierComponents[optional: 1],
               let enumMemoryComponent = helpers.first(where: { $0.enumeration?.name == namespace }),
               let value = enumMemoryComponent.enumeration!.cases[enumCaseString] {
                return definiteComponent.replacingOccurrences(of: "@\(tag)", with: value)
            }

            CLIStateController.terminate("Parse error (\(name)): unknown header, macro or enum '\(tag)'")
        } else {
            return definiteComponent
        }
    }
}
