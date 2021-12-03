//
//  DocumentateCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 03/12/2021.
//

final class DocumentationCommand: Command {
    override func execute(with stateContext: StateContext) {
        let documentations = CLIStateController.arguments.count < 3 ?
            stateContext.directoryCreate(named: "api") :
            stateContext.directoryCreate(named: CLIStateController.arguments[3])
        let headers = stateContext.directoryCreate(
            named: "headers",
            at: documentations)

        // TODO:
        // A new command architecture which has a global stateContext, and which allows the
        // command to have methods which can use that state.
        stateContext.storage.memoryComponents
            .map { $0.transpiler.tags() }
            .filter { $0.header != nil }
            .forEach { memoryComponent in
                stateContext.write(
                    toFile: memoryComponent.name,
                    at: headers,
                    data: headerContent(of: memoryComponent))
            }
    }

    private func headerContent(of memoryComponent: MemoryComponent) -> String {
        let header = memoryComponent.header!
        return [
            "# \(header.name)\n",
            "### Parameters\n",
            header.parameters.joined(separator: ", ")
        ].byNewlines()
    }
}
