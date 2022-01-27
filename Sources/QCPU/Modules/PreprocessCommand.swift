//
//  PreprocessCommand.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 27/01/2022.
//

final class PreprocessCommand: Command {

    lazy var assembly = stateContext.directoryCreate(named: "assembly")

    override func execute() {
        stateContext.preprocessor()

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
        for (index, segmentComponents) in segments {
            let segment = stateContext.directoryCreate(
                named: String(index),
                at: assembly)
            segmentComponents.forEach { page in
                stateContext.write(
                    toFile: "\(page.address.page).txt",
                    at: segment,
                    data: page.representativeStrings.byNewlines())
            }
        }
    }
}
