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
            print("\($0.name) (\($0.representativeStrings.count))")
            print($0.representativeStrings)
        }

        let segments = Dictionary(
            grouping: stateContext.memoryComponents,
            by: { $0.address.segment })
        outputSegmentComponents(segments)
    }

    private func outputSegmentComponents(_ segments: [Int: [MemoryComponent]]) {
        for segmentComponent in segments {
            let segment = stateContext.directoryCreate(
                named: String(segmentComponent.key),
                at: build)
            segmentComponent.value.forEach { page in
                stateContext.write(
                    toFile: "\(page.address.page).txt",
                    at: segment,
                    data: page.binary.dictionary
                        .map { $1.formatted }
                        .joined(separator: "\n"))
            }
        }
    }
}
