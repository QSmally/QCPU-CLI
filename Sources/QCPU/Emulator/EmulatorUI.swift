//
//  EmulatorUI.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 13/12/2021.
//

extension EmulatorStateController {

    var columns: [[String]] {
        [
            (dataComponent?.compiled
                .sorted { $0.key < $1.key }
                .map { " - \($0): \($1.value)" } ?? [])
                .inserted("Data Memory", at: 0)
                .inserted("(\(dataComponent?.name ?? "untitled"))", at: 1),
            (instructionComponent?.compiled
                .sorted { $0.key < $1.key }
                .map { " \(line == $0 ? ">" : "-") \($0): \($1.formatted) (\($1.value))" } ?? [])
                .inserted("Instruction Memory", at: 0)
                .inserted("(\(instructionComponent?.name ?? "untitled"))", at: 1),
            registers
                .sorted { $0.key < $1.key }
                .map { " - B\($0): \($1)" }
                .inserted("Registers", at: 0)
                .inserted(" - A0: \(accumulator)", at: 1),
            [
                "State",
                " - Page line: \(line)",
                " - Segment address: \(mmu.intermediateSegmentAddress)"
            ]
        ]
    }

    func updateUI() {
        CLIStateController.clear()
        var columnComponent = 0
        var lastRowIndex = 0

        for column in columns {
            let rows = column
                .map { $0.padding(toLength: 24) }
                .enumerated()

            for (index, row) in rows {
                CLIStateController.output("\u{1B}[\(index + 1);\(columnComponent * 24)H")
                CLIStateController.output(row)
                lastRowIndex = index + 3
            }

            columnComponent += 1
        }

        CLIStateController.output("\u{1B}[\(lastRowIndex);\((columnComponent - 1) * 24)H")
        CLIStateController.output("Ports")

        for (index, row) in outputStream.enumerated() {
            CLIStateController.output("\u{1B}[\(index + lastRowIndex + 1);\((columnComponent - 1) * 24)H")
            CLIStateController.output(" - \(row)".padding(toLength: 24))
        }
    }
}
