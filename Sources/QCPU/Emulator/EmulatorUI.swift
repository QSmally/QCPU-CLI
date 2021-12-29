//
//  EmulatorUI.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 13/12/2021.
//

import Dispatch

extension EmulatorStateController {

    var columns: [[String]] {
        [
            // Data memory
            (dataComponent?.compiled
                .sorted { $0.key < $1.key }
                .map { " - \(String($0).padding(toLength: 2)): \($1.value)".padding(toLength: 24) } ?? [])
                .inserted("Data Memory", at: 0)
                .inserted("(\(dataComponent?.name ?? "untitled"))", at: 1),

            // Instruction memory
            (instructionComponent?.compiled
                .sorted { $0.key < $1.key }
                .map { " \(line == $0 ? ">" : "-") \(String($0).padding(toLength: 2)): \($1.formatted) (\($1.value))" } ?? [])
                .inserted("Instruction Memory", at: 0)
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
                " - Segment address: \(mmu.intermediateSegmentAddress)",
                " - Total cycles: \(cycles)",
                " - Mode: \(mode)"
            ]
                // Stacks and output
                .inserted([String.empty, "Ports"])
                .inserted(outputStream.map { " - \($0)" })
                .inserted([String.empty, "Parameter stack"])
                .inserted(mmu.parameters.map { " - \($0)" })
                .inserted([String.empty, "Call stack"])
                .inserted(mmu.addressCallStack.map { " - \($0)" })
        ]
    }

    func updateUI() {
        CLIStateController.output("\u{1B}[2J")
        var columnComponent = 0

        for column in columns {
            for (index, row) in column.enumerated() {
                CLIStateController.output("\u{1B}[\(index + 1);\(columnComponent * 24)H")
                CLIStateController.output(row)
            }

            columnComponent += 1
        }
    }
}
