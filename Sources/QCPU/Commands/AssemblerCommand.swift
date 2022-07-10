//
//  AssemblerCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

final class AssemblerCommand: Command {

    lazy var build = stateContext.directoryCreate(named: "build")

    override func execute() {
        stateContext
            .preprocessor()
            .references()
            .transpile()

        stateContext.memoryComponents.forEach {
            print("\($0.name) (\($0.binary.dictionary.count))")
            print($0.binary.dictionary
                .sorted { $0.key < $1.key }
                .map { $0.value.representativeString })
        }

        let segments = Dictionary(
            grouping: stateContext.memoryComponents,
            by: { $0.address.segment })
        outputSegmentComponents(segments)
    }

    private func outputSegmentComponents(_ segments: [Int: [MemoryComponent]]) {
        for (index, segmentComponents) in segments {
            let segment = stateContext.directoryCreate(
                named: String(index),
                at: build)
            segmentComponents.forEach { page in
                stateContext.write(
                    toFile: "\(page.address.page).txt",
                    at: segment,
                    data: page.binary.dictionary
                        .map { $1.formatted }
                        .byNewlines())
            }
        }
    }
}
