//
//  Addressing.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

extension MemoryComponent {
    func labels() -> [Label] {
        file.compactMap { instruction in
            if let labelTarget = Expressions.label.match(instruction, group: 2) {
                let isPublicLabel = Expressions.label.match(instruction, group: 1) == "&"
                let address = Address(
                    segment: address!.segment,
                    page: address!.page,
                    line: lineIteratorCount)
                return Label(
                    id: labelTarget,
                    address: address,
                    privacy: isPublicLabel ? .segment : .page)
            } else {
                lineIteratorCount += 1
                return nil
            }
        }
    }

    func insertAddressTargets(labels: [Label]) {
        for statement in file.removeCopy() {
            guard Expressions.label.match(statement, group: 0) == nil else {
                continue
            }

            if let labelId = Expressions.address.match(statement, group: 1),
               let replaceable = Expressions.address.match(statement, group: 0),
               let addressingModeTarget = Expressions.address.match(statement, group: 2) {
                guard let label = labels.first(where: { $0.id == labelId }) else {
                    CLIStateController.terminate("Parse error (\(name)): undeclared or unaddressed label '\(labelId)'")
                }

                guard label.privacy == .global || label.address.segment == address!.segment else {
                    CLIStateController.terminate("Parse error (\(name)): label '\(labelId)' is declared out of the segment scope, use '@ADDRESSABLE' instead")
                }

                guard label.privacy != .page || label.address.page == address!.page else {
                    CLIStateController.terminate("Parse error (\(name)): private label '\(labelId)' is used within a different page")
                }

                let addressedStatement = statement.replacingOccurrences(
                    of: replaceable,
                    with: label.address.parse(mode: addressingModeTarget))
                file.append(addressedStatement)
                continue
            }

            file.append(statement)
        }
    }
}
