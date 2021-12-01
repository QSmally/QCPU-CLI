//
//  MemoryComponent.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

import Foundation

final class MemoryComponent {

    var name: String
    var address: Address?
    var namespaceCallable: String?
    var overflowable = false

    var header: (
        name: String,
        parameters: [String])?
    var enumeration: (
        name: String,
        cases: [String: String])?
    var declarations = [String: String]()

    var file: [String]
    var compiled = [CompiledStatement]()
    lazy var transpiler = Transpiler(self)

    init(_ name: String, fromSource instructions: [String]) {
        self.name = name
        self.file = instructions
    }

    static func create(url: String) -> MemoryComponent {
        let fileContents = try! String(contentsOfFile: url)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.starts(with: "//") }
        let filename = URL(fileURLWithPath: url)
            .deletingPathExtension()
            .lastPathComponent
        return MemoryComponent(filename, fromSource: fileContents)
    }

    func clone() -> MemoryComponent {
        let clonedMemoryComponent = MemoryComponent(name, fromSource: file)
        clonedMemoryComponent.header = header
        clonedMemoryComponent.enumeration = enumeration
        clonedMemoryComponent.declarations = declarations

        return clonedMemoryComponent
    }
}
