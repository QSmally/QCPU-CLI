//
//  TerminalUI.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 13/12/2021.
//

extension EmulatorStateController {

    var columns: [[String]] {
        [
            // Data memory
            (dataComponent?.binary.dictionary
                .map { " - \(String($0).padding(toLength: 2)): \($1.value) (\($1.formatted))" }
                .map { $0.padding(toLength: 24) } ?? [])
                // dataCacheValidated 'V'valid 'I'nvalid
                // dataCacheNeedsStore 'M'modified/unsynced 'U'nchanged/static
                .inserted("Data Memory (\(mmu.dataCacheValidated ? "V" : "I")) (\(mmu.dataCacheNeedsStore ? "D" : "S"))", at: 0)
                .inserted("(\(dataComponent?.name ?? "untitled"))", at: 1),

            // Instruction memory
            (instructionComponent?.binary.dictionary
                .map { " \(line == $0 ? ">" : "-") \(String($0).padding(toLength: 2)): \($1.formatted) (\($1.value))" }
                .map { $0.padding(toLength: 24) } ?? [])
                .inserted("Instruction Memory (\(mmu.instructionCacheValidated ? "V" : "I"))", at: 0)
                .inserted("(\(instructionComponent?.name ?? "untitled"))", at: 1),

            [
                // Registers
                "Registers",
                registers
                    .sorted { $0.key < $1.key }
                    .map { "B\($0.key)".padding(toLength: 4) }
                    .inserted("A0".padding(toLength: 4), at: 0)
                    .joined(),
                registers
                    .sorted { $0.key < $1.key }
                    .map { String($0.value).padding(toLength: 4) }
                    .inserted(String(accumulator).padding(toLength: 4), at: 0)
                    .joined(),
                String.empty,

                // State
                "State",
                " - Page line: \(line)",
                " - Total cycles: \(cycles)",
                " - Segment address: \(mmu.instructionSegment)",
                " - Data context address: \(mmu.kernelDataContext ?? mmu.dataContext ?? mmu.instructionSegment)",
                " - Mode: \(mode)"
            ]
                // Stacks and output
                .inserted([String.empty, "Ports"])
                .inserted(outputStream.map { " - \($0)" })
                .inserted([String.empty, "Parameter stack"])
                .inserted(mmu.parameterStack.map { " - \($0)" })
                .inserted([String.empty, "Call stack"])
                .inserted(mmu.callStack.map { " - \($0)" })
        ]
    }

    func updateUI() {
        renderedStream.append("\u{1B}[2J")
        var columnComponent = 0

        for column in columns {
            for (index, row) in column.enumerated() {
                renderedStream.append("\u{1B}[\(index + 1);\(columnComponent * 24)H")
                renderedStream.append(row)
            }

            columnComponent += 1
        }

        CLIStateController.output(renderedStream)
        renderedStream.removeAll(keepingCapacity: true)
    }
}
