//
//  Addressing.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

extension Transpiler {
    func labels() -> [MemoryComponent.Label] {
        let labels: [MemoryComponent.Label] = memoryComponent.file.compactMap { instruction in
            if let labelTarget = Expressions.label.match(instruction, group: 2) {
                let isPublicLabel = Expressions.label.match(instruction, group: 1) == "&"
                let address = MemoryComponent.Address(
                    segment: memoryComponent.address.segment,
                    page: memoryComponent.address.page,
                    line: lineIteratorCount)
                return MemoryComponent.Label(
                    id: labelTarget,
                    address: address,
                    privacy: isPublicLabel ? .segment : .page)
            } else {
                lineIteratorCount += 1
                return nil
            }
        }

        lineIteratorCount = 0
        return labels
    }

    func insertAddressTargets(labels: [MemoryComponent.Label]) {
        for statement in memoryComponent.file.removeCopy() {
            guard Expressions.label.match(statement, group: 0) == nil else {
                continue
            }

            if let labelId = Expressions.address.match(statement, group: 1),
               let replaceable = Expressions.address.match(statement, group: 0),
               let ignoreSegment = Expressions.address.match(statement, group: 2),
               let addressingModeTarget = Expressions.address.match(statement, group: 3) {
                let labels = labels.filter({ $0.id == labelId })

                guard labels.count > 0 else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): undeclared or unaddressed label '\(labelId)'")
                }

                let label = priorityAddress(from: labels)

                guard label.privacy == .global ||
                      ignoreSegment == "!" ||
                      label.address.equals(to: memoryComponent.address, basedOn: .segment) else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): label '\(labelId)' is declared out of the segment scope, use '@ADDRESSABLE' or '.\(labelId)!\(addressingModeTarget)' instead")
                }

                guard label.privacy != .page || label.address.equals(to: memoryComponent.address, basedOn: .page) else {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): private label '\(labelId)' is used within a different page")
                }

                let addressedStatement = statement.replacingOccurrences(
                    of: replaceable,
                    with: label.address.parse(mode: addressingModeTarget))
                memoryComponent.file.append(addressedStatement)
                continue
            }

            memoryComponent.file.append(statement)
        }
    }

    private func priorityAddress(from labels: [MemoryComponent.Label]) -> MemoryComponent.Label {
        let privateScopedPriorityLabel = labels
            .filter { $0.address.equals(to: memoryComponent.address, basedOn: .page) }
            .sorted { $0.address.line > $1.address.line }
            .first
        return privateScopedPriorityLabel ?? labels
            .sorted { (entity, _) in entity.privacy == .segment }
            .first!
    }
}
