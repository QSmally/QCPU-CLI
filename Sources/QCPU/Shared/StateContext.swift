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

    @discardableResult
    func deobfuscate() -> StateContext {
        memoryComponents
            .map { $0.tags() }
            .filter { $0.isCodeBlock }
            .forEach { $0.prepare(helpers: memoryComponents.insertable) }
        memoryComponents
            .removeAll { !$0.isCodeBlock }
        return self
    }

    @discardableResult
    func addressTargets() -> StateContext {
        let addressables = memoryComponents
            .filter { $0.namespaceCallable != nil }
            .map { MemoryComponent.Label(
                id: $0.namespaceCallable!,
                address: MemoryComponent.Address(segment: $0.address!.segment, page: $0.address!.page),
                privacy: .global) }

        let labels = memoryComponents.flatMap { $0.labels() }
        memoryComponents.forEach { $0.insertAddressTargets(labels: addressables + labels) }
        return self
    }
}
