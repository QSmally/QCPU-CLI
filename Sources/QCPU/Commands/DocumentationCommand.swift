//
//  DocumentateCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 03/12/2021.
//

import Foundation

final class DocumentationCommand: Command {

    lazy var documentations: URL = {
        let path = CLIStateController.argument(withId: "dest")
        return stateContext.directoryCreate(named: path ?? "api")
    }()

    override func execute() {
        let headers = stateContext.directoryCreate(
            named: "headers",
            at: documentations)
        stateContext.memoryComponents
            .map { $0.transpiler.parseTags() }
            .filter { $0.header != nil }
            .forEach { headerContent(memoryComponent: $0, at: headers) }
    }

    private func headerContent(memoryComponent: MemoryComponent, at path: URL) {
        let headerContent = [
            "# \(memoryComponent.header!.name)\n",
            "### Parameters\n",
            memoryComponent.header!.parameters
                .map { "* `\($0)`" }
                .joined(separator: "\n")
        ].byNewlines()

        stateContext.write(
            toFile: memoryComponent.name,
            at: path,
            data: headerContent)
    }
}
