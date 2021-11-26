//
//  MemoryComponent.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

import Foundation

class MemoryComponent {

    static let validTags = [
        "@PAGE", "@HEADER", "@ADDRESSABLE", "@OVERFLOWABLE",
        "@DECLARE", "@ENUM", "@END"]
    static let indentedTagNotations = ["@ENUM"]
    static let breakTaglike = ["@IF"]

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

    // Accumulated outputs
    var file: [String]
    var assemblyOutlet = [String]()

    // Working area
    internal var tagAmount = 0
    internal var lineIteratorCount: UInt = 0
    internal var indentations = [IndentationController]()
    internal var declarations = [String: String]()

    var isCodeBlock: Bool {
        address != nil && header == nil
    }

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
