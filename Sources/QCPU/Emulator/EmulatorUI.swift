//
//  EmulatorUI.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 13/12/2021.
//

import Dispatch

extension EmulatorStateController {

    var kernelInformation: [String] {
        let depthSequence = [
            [String.empty, "Parameter stack"],
            mmu.parameters.map { " - \($0)" },
            [String.empty, "Call stack"],
            mmu.addressCallStack.map { " - \($0)" }
        ]

        return Array(depthSequence.joined())
    }

    var columns: [[String]] {
        [
            (dataComponent?.compiled
                .sorted { $0.key < $1.key }
                .map { " - \(String($0).padding(toLength: 2)): \($1.value)" } ?? [])
                .inserted("Data Memory", at: 0)
                .inserted("(\(dataComponent?.name ?? "untitled"))", at: 1),
            (instructionComponent?.compiled
                .sorted { $0.key < $1.key }
                .map { " \(line == $0 ? ">" : "-") \(String($0).padding(toLength: 2)): \($1.formatted) (\($1.value))" } ?? [])
                .inserted("Instruction Memory", at: 0)
                .inserted("(\(instructionComponent?.name ?? "untitled"))", at: 1),
            registers
                .sorted { $0.key < $1.key }
                .map { " - B\($0): \($1)" }
                .inserted("Registers", at: 0)
                .inserted(" - A0: \(accumulator)", at: 1)
                .inserted(kernelInformation),
            [
                "State",
                " - Page line: \(line)",
                " - Segment address: \(mmu.intermediateSegmentAddress)",
                " - Total cycles: \(cycles)"
            ]
                .inserted(String.empty)
                .inserted("Ports")
                .inserted(outputStream.map { " - \($0)" })
        ]
    }

    var widthColumn: Int { 24 }

    func updateUI() {
        var columnComponent = 0
        var nextRowIndex = 0

        for column in columns {
            let rows = column
                .map { $0.padding(toLength: widthColumn) }
                .enumerated()

            for (index, row) in rows {
                CLIStateController.output("\u{1B}[\(index + 1);\(columnComponent * widthColumn)H")
                CLIStateController.output(row)
                nextRowIndex = index + 1
            }

            for removalRowIndex in nextRowIndex...64 {
                CLIStateController.output("\u{1B}[\(removalRowIndex + 1);\(columnComponent * widthColumn)H")
                CLIStateController.output("".padding(toLength: widthColumn))
            }

            columnComponent += 1
        }
    }
}
