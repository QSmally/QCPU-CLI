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
        "@DECLARE", "@IF", "@ENUM", "@END"]
    static let indentedTagNotations = ["@IF", "@ENUM"]

    var name: String
    var address: (UInt, UInt)?
    var namespaceCallable: String?

    // Accumulated outputs
    var file: [String]
    var assemblyOutlet = [String]()

    // Working area
    internal var tagAmount = 0
    internal var indentations = [IndentationLevel]()

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
}
