//
//  References.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

extension Transpiler {
    func label(rawString line: String) -> MemoryComponent.Label? {
        if let labelTarget = Expressions.label.match(line, group: 2) {
            if !Expressions.label.match(line, group: 3)!.isEmpty {
                let addressTarget = Expressions.label.match(line, group: 4)!

                guard let parsedOrg = Int(addressTarget) else {
                    CLIStateController.terminate("Parse error: invalid org address '\(addressTarget)'")
                }

                memoryComponent.binary.pointer = parsedOrg
            }

            let isPublicLabel = Expressions.label.match(line, group: 1) == "&"
            let address = MemoryComponent.Address(
                segment: memoryComponent.address.segment,
                page: memoryComponent.address.page,
                line: memoryComponent.binary.pointer)
            return MemoryComponent.Label(
                id: labelTarget,
                address: address,
                privacy: isPublicLabel ? .segment : .page)
        } else {
            let statement = MemoryComponent.Statement(fromString: line)
            memoryComponent.binary.append(statement)
            return nil
        }
    }

    func removeAbstraction(labels: [MemoryComponent.Label]) {
        for (index, immutableStatement) in memoryComponent.binary.dictionary {
            if let labelId = Expressions.address.match(immutableStatement.representativeString, group: 1),
               let replacable = Expressions.address.match(immutableStatement.representativeString, group: 0),
               let ignoreSegmentPrivacy = Expressions.address.match(immutableStatement.representativeString, group: 2),
               let addressingMode = Expressions.address.match(immutableStatement.representativeString, group: 3) {
                let labels = labels.filter { $0.id == labelId }

                guard labels.count > 0 else {
                    CLIStateController.terminate("Parse error: undeclared or unaddressed label '\(labelId)'")
                }

                let label = priorityAddress(fromLabels: labels)

                guard label.privacy == .global ||
                      ignoreSegmentPrivacy == "!" ||
                      label.address.equals(toSegment: memoryComponent.address) else {
                          CLIStateController.terminate("Parse error: label '\(labelId)' is declared out of the segment scope, use '@ADDRESSABLE' or '\(labelId)!\(addressingMode)' instead")
                }

                guard label.privacy != .page ||
                      label.address.equals(toPage: memoryComponent.address) else {
                    CLIStateController.terminate("Parse error: private label '\(labelId)' is used within a different page")
                }

                let addressedStatement = immutableStatement.representativeString.replacingOccurrences(
                    of: replacable,
                    with: label.address.parse(mode: addressingMode))
                memoryComponent.binary.dictionary[index]?.representativeString = addressedStatement
            }
        }
    }

    private func priorityAddress(fromLabels labels: [MemoryComponent.Label]) -> MemoryComponent.Label {
        let privateScopedPriorityLabel = labels
            .filter { $0.address.equals(toPage: memoryComponent.address) }
            .sorted { $0.address.line > $1.address.line }
            .first
        return privateScopedPriorityLabel ?? labels
            .sorted { (entity, _) in entity.privacy == .segment }
            .first!
    }
}
