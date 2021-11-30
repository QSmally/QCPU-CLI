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

        stateContext.memoryComponents.forEach {
            print($0.name)
            print($0.file)
        }
    }
}
