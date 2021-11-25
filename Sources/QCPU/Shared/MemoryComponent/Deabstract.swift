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

    func prepare(helpers: [MemoryComponent]) -> MemoryComponent {
        for statement in file {
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

            // TODO:
            // Autocomplete functions like %random and %array.

            if let tag = Expressions.tag.match(statement, group: 1) {
                let instructions = parseMarcoHeader(tag, from: statement, helpers: helpers)
                temporaryStack += instructions
                continue
            }

            temporaryStack.append(statement)
        }

        file = temporaryStack
        temporaryStack.removeAll()
        return self
    }

    private func parseMarcoHeader(_ tag: String, from statement: String, helpers: [MemoryComponent]) -> [String] {
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
                // Somehow the 'arguments' array slice is not zero-indexed because it uses the
                // length of the non-first-dropped array.
                headerComponent.declarations[name] = arguments[index + 1]
            }

            return headerComponent
                .prepare(helpers: helpers)
                .file
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
}
