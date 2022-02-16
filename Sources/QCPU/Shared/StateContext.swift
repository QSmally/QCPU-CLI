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

    var insertableComponents: [MemoryComponent] {
        memoryComponents.filter { $0.header != nil || $0.enumeration != nil }
    }

    lazy var memoryComponents: [MemoryComponent] = {
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
            return iterator.allObjects
                .map { ($0 as! NSURL).relativePath! }
                .filter { $0.hasSuffix(".s") }
                .map { MemoryComponent.create(url: $0) }
        }

        CLIStateController.terminate("Fatal error: missing permissions to read directory")
    }()

    lazy var defaults: EmulatorDefaults = {
        let defaultsSource = URL(fileURLWithPath: CLIStateController.arguments[2])
            .appendingPathComponent("defaults.json")
        guard fileContext.fileExists(atPath: defaultsSource.relativePath) else {
            return EmulatorDefaults()
        }

        guard let decoded = try? JSONDecoder().decode(EmulatorDefaults.self, from: Data(contentsOf: defaultsSource)) else {
            CLIStateController.terminate("Fatal error: could not parse 'defaults.json'")
        }

        return decoded
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

    // Tags, headers and macros
    @discardableResult func preprocessor() -> StateContext {
        memoryComponents
            .map { $0.transpiler.parseTags() }
            .filter { $0.transpiler.isCodeBlock }
            .forEach { $0.transpiler.preprocessor(withComponents: insertableComponents) }

        memoryComponents
            .removeAll { !$0.transpiler.isCodeBlock }

        return self
    }

    // Labels and addressing
    @discardableResult func references() -> StateContext {
        let addressables = memoryComponents
            .filter { $0.namespaceCallable != nil }
            .map { MemoryComponent.Label(
                id: $0.namespaceCallable!,
                address: $0.address,
                privacy: .global) }

        let labels = memoryComponents.flatMap { memoryComponent in
            memoryComponent.representativeStrings.compactMap { memoryComponent.transpiler.label(rawString: $0) }
        }

        memoryComponents
            .map { $0.transpiler.pagesGenerated }
            .forEach { memoryComponents.append(contentsOf: $0) }
        let grouped = Dictionary(grouping: memoryComponents, by: \.address.bitfield)

        if let duplicateGroup = grouped.first(where: { $0.value.count > 1 }),
           let address = duplicateGroup.value.first?.address {
            CLIStateController.terminate("Address error: duplicate address (\(address.segment), \(address.page))")
        }

        memoryComponents
            .forEach { $0.transpiler.removeAbstraction(labels: addressables + labels) }
        return self
    }

    // Transpiler to QCPU 2 machine binary
    @discardableResult func transpile() -> StateContext {
        memoryComponents
            .forEach { $0.transpiler.transpile() }
        return self
    }
}
