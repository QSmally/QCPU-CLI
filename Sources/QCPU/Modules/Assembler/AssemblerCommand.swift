//
//  AssemblerCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

class AssemblerCommand: Command {
    override func execute(with stateContext: StateContext) {
        stateContext
            .deobfuscate()
            .addressTargets()
            // .transpile()

        print(stateContext.memoryComponents.map { ($0.name, $0.file) })
    }
}
