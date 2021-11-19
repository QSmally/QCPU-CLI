//
//  StateContext.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

import Foundation

class StateContext {

    unowned var controller: CLIStateController

    lazy var memoryComponents: [MemoryComponent] = {
        if CLIStateController.arguments.count < 2 {
            CLIStateController.terminate("Fatal error: input a source directory path")
        }

        let directorySource = URL(fileURLWithPath: CLIStateController.arguments[2])
        var fileIsDirectory: ObjCBool = false

        if !FileManager.default.fileExists(
            atPath: directorySource.relativePath,
            isDirectory: &fileIsDirectory) {
            CLIStateController.terminate("Fatal error: invalid directory")
        } else if !fileIsDirectory.boolValue {
            CLIStateController.terminate("Fatal error: source path must be a directory")
        }

        let iterator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directorySource.relativePath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        if let iterator = iterator {
            return iterator.allObjects
                .map { ($0 as! NSURL).relativePath! }
                .filter { $0.hasSuffix(".s") }
                .map { MemoryComponent.create(url: $0) }
        }

        CLIStateController.terminate("Fatal error: missing permissions to read directory")
    }()

    init(controller: CLIStateController) {
        self.controller = controller
    }
}
