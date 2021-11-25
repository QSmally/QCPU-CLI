//
//  AssemblerCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

class AssemblerCommand: Command {
    override func execute(with stateContext: StateContext) {
        let _ = stateContext.memoryComponents
            .map { $0.tags() }
            .map { $0.prepare(helpers: stateContext.memoryComponents.insertable) }
            .map { $0.name }
        stateContext.memoryComponents
            .removeAll { !$0.isCodeBlock }

        print(stateContext.memoryComponents.map { $0.file })
    }
}
