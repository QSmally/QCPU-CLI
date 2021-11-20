//
//  AssemblerCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

class AssemblerCommand: Command {
    override func execute(with stateContext: StateContext) {
        print(stateContext.memoryComponents.map { $0.name })
        stateContext.memoryComponents.forEach { $0.tags() }
    }
}
