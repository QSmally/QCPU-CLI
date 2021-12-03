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

        let build = stateContext.directoryCreate(named: "build")
        let segments = Dictionary(
            grouping: stateContext.storage.memoryComponents,
            by: { $0.address!.segment })

        for segmentComponent in segments {
            let segment = stateContext.directoryCreate(
                named: String(segmentComponent.key),
                at: build)
            segmentComponent.value.forEach { page in
                stateContext.write(
                    toFile: "\(page.address!.page).txt",
                    at: segment,
                    data: page.file.joined(separator: "\n"))
            }
        }
    }
}
