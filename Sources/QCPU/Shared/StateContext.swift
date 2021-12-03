//
//  StateContext.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

import Foundation

final class StateContext {

    unowned var controller: CLIStateController

    var fileContext = FileManager.default

    lazy var storage: StorageComponent = {
        if CLIStateController.arguments.count < 2 {
            CLIStateController.terminate("Fatal error: input a source directory path")
        }

        let directorySource = URL(fileURLWithPath: CLIStateController.arguments[2])
        var fileIsDirectory: ObjCBool = false

        if !fileContext.fileExists(
            atPath: directorySource.relativePath,
            isDirectory: &fileIsDirectory) {
            CLIStateController.terminate("Fatal error: invalid directory")
        } else if !fileIsDirectory.boolValue {
            CLIStateController.terminate("Fatal error: source path must be a directory")
        }

        let iterator = fileContext.enumerator(
            at: URL(fileURLWithPath: directorySource.relativePath),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        if let iterator = iterator {
            let memoryComponents = iterator.allObjects
                .map { ($0 as! NSURL).relativePath! }
                .filter { $0.hasSuffix(".s") }
                .map { MemoryComponent.create(url: $0) }
            return StorageComponent(memoryComponents)
        }

        CLIStateController.terminate("Fatal error: missing permissions to read directory")
    }()

    init(controller: CLIStateController) {
        self.controller = controller
    }

    func directoryCreate(named name: String, at path: URL? = nil, overwrite: Bool = true) -> URL {
        let absolutePathTarget = path == nil ?
            URL(fileURLWithPath: name) :
            path!.appendingPathComponent(name, isDirectory: true)
        if fileContext.fileExists(atPath: absolutePathTarget.relativePath) && overwrite {
            try! fileContext.removeItem(at: absolutePathTarget)
        }

        try! fileContext.createDirectory(
            at: absolutePathTarget,
            withIntermediateDirectories: true,
            attributes: nil)

        return absolutePathTarget
    }

    func write(toFile file: String, at path: URL, data: String) {
        let absolutePathTarget = path.appendingPathComponent(file)
        fileContext.createFile(
            atPath: absolutePathTarget.relativePath,
            contents: Data(data.utf8),
            attributes: nil)
    }
}
