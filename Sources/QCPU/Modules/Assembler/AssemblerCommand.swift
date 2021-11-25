//
//  AssemblerCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

class AssemblerCommand: Command {
    override func execute(with stateContext: StateContext) {
        stateContext.memoryComponents.forEach { $0.tags() }
        let executionComponents = stateContext.memoryComponents
            .filter { $0.isCodeBlock }
            .map { $0.prepare(helpers: stateContext.memoryComponents.insertable) }
        stateContext.memoryComponents = executionComponents

        print(stateContext.memoryComponents.map { ($0.name, $0.file) })
    }
}
