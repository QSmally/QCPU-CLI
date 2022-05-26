//
//  CoverageCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 26/05/2022.
//

import Foundation

final class CoverageCommand: Command {

    lazy var segments: String = {
        Dictionary(grouping: stateContext.memoryComponents, by: { $0.address.segment })
            .sorted { $0.key < $1.key }
            .map { "\($0): " + $1
                .sorted { $0.address.page < $1.address.page }
                .map { "\($0.address.page) (\($0.binary.dictionary.count)/32)" }
                .joined(separator: ", ") }
            .joined(separator: "\n")
    }()

    override func execute() {
        stateContext
            .preprocessor()
            .references()
            .transpile()

        if !segments.isEmpty {
            CLIStateController.newline("seg: page (lines/32)")
            CLIStateController.newline(segments)
        }
    }
}
