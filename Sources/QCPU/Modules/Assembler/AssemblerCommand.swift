//
//  AssemblerCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

final class AssemblerCommand: Command {
    override func execute(with stateContext: StateContext) {
        stateContext.storage
            .deobfuscate()
            .addressTargets()
            .transpile()

        stateContext.storage.memoryComponents.forEach {
            print($0.name)
            print($0.file)
        }
    }
}
