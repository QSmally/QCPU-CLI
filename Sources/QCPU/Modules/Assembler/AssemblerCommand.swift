//
//  AssemblerCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

class AssemblerCommand: Command {
    override func execute(with stateContext: StateContext) {
        let files = stateContext.files
            .map { file in
                file
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.starts(with: "//") }
            }
        print(files)
    }
}
