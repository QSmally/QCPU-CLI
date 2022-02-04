//
//  References.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

extension Transpiler {
    func label(rawString line: String) -> MemoryComponent.Label? {
        if memoryComponent.binary.pointer >> 5 != 0 {
            guard memoryComponent.overflowable else {
                CLIStateController.terminate("Address error: page \(memoryComponent.name) ran out of addressing without being marked as '@OVERFLOWABLE'")
            }

            // TODO: page amount overflows (maximum of 8 pages)
            let address = MemoryComponent.Address(
                segment: memoryComponent.address.segment,
                page: memoryComponent.address.page + 1)

            let overflowComponent = MemoryComponent.empty(memoryComponent.name, atAddress: address)
            overflowComponent.overflowable = memoryComponent.overflowable
            overflowComponent.declarations = memoryComponent.declarations
            overflowComponent.purpose = .extended

            pagesGenerated.append(overflowComponent)
            memoryComponent.binary.pointer = 0
        }

        let referenceComponent = pagesGenerated
            .filter { $0.purpose == .extended }
            .last ?? memoryComponent

        if let labelTarget = Expressions.label.match(line, group: 2) {
            if !Expressions.label.match(line, group: 3)!.isEmpty {
                let addressTarget = Expressions.label.match(line, group: 4)!

                guard let parsedOrg = Int.parse(fromString: addressTarget) else {
                    CLIStateController.terminate("Parse error: invalid org address '\(addressTarget)'")
                }

                referenceComponent.binary.pointer = parsedOrg
            }

            let isPublicLabel = Expressions.label.match(line, group: 1) == "&"
            let address = MemoryComponent.Address(
                segment: referenceComponent.address.segment,
                page: referenceComponent.address.page,
                line: referenceComponent.binary.pointer)
            return MemoryComponent.Label(
                id: labelTarget,
                address: address,
                privacy: isPublicLabel ? .segment : .page)
        } else {
            if let ascii = Expressions.ascii.match(line, group: 1) {
                // TODO: fix incorrect placement of characters when on the edge of page overflow
                for asciiCharacter in ascii.utf8 {
                    let asciiStatement = MemoryComponent.Statement(fromString: String(asciiCharacter))
                        .transpile(
                            value: Int(asciiCharacter),
                            botherCompileInstruction: false)
                    referenceComponent.binary.append(asciiStatement)
                }
            } else {
                let statement = MemoryComponent.Statement(fromString: line)
                referenceComponent.binary.append(statement)
            }

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
                          CLIStateController.terminate("Address error: label '\(labelId)' is declared out of the segment scope, use '@ADDRESSABLE' or '\(labelId)!\(addressingMode)' instead")
                }

                guard label.privacy != .page ||
                      label.address.equals(toPage: memoryComponent.address) else {
                    CLIStateController.terminate("Address error: private label '\(labelId)' is used within a different page")
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
