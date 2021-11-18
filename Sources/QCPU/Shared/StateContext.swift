//
//  StateContext.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

import Foundation

class StateContext {

    unowned var controller: CLIStateController

    var memoryComponents = [MemoryComponent]()

    lazy var files: [String] = {
        let directorySource = FileManager.default.currentDirectoryPath
        let iterator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directorySource),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        if let iterator = iterator {
            return iterator.allObjects
                .map { ($0 as! NSURL).absoluteString! }
                .filter { $0.hasSuffix(".s") }
                .map { try! String(contentsOfFile: $0) }
        }

        CLIStateController.exit("Fatal error: invalid directory or permissions")
    }()

    init(controller: CLIStateController) {
        self.controller = controller
    }
}
