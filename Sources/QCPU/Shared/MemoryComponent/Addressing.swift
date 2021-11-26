//
//  Addressing.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

extension MemoryComponent {

    struct Label: Identifiable {

        let id: String
        let address: (segment: UInt, page: UInt, line: UInt)
        let privacy: Privacy

        enum Privacy {
            case global,
                 segment,
                 page

            static func from(boolean isPublic: Bool) -> Privacy {
                isPublic ? .segment : .page
            }
        }
    }

    func labels() -> [Label] {
        file.compactMap { instruction in
            if let labelTarget = Expressions.label.match(instruction, group: 2) {
                let isPublicLabel = Expressions.label.match(instruction, group: 1) == "&"
                let address = (
                    segment: address!.0,
                    page: address!.1,
                    line: lineIteratorCount)
                return Label(
                    id: labelTarget,
                    address: address,
                    privacy: Label.Privacy.from(boolean: isPublicLabel))
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

            if let labelId = Expressions.address.match(statement, group: 1) {
                let replaceable = Expressions.address.match(statement, group: 0)!
                let addressingModeTarget = Expressions.address.match(statement, group: 2) ?? "_"

                guard let label = labels.first(where: { $0.id == labelId }) else {
                    CLIStateController.terminate("Parse error (\(name)): undeclared or addressless label '\(labelId)'")
                }

                guard label.privacy == .global || label.address.segment == address!.0 else {
                    CLIStateController.terminate("Parse error (\(name)): label '\(labelId)' is declared out of the segment scope, use '@ADDRESSABLE' instead")
                }

                guard label.privacy == .segment || label.address.page == address!.1 else {
                    CLIStateController.terminate("Parse error (\(name)): private label '\(labelId)' is used within a different page")
                }

                let addressedStatement = statement.replacingOccurrences(
                    of: replaceable,
                    with: parse(address: label.address, mode: addressingModeTarget))
                file.append(addressedStatement)
                continue
            }

            file.append(statement)
        }
    }

    private func parse(address: (segment: UInt, page: UInt, line: UInt), mode: String) -> String {
        return "0"
    }
}
