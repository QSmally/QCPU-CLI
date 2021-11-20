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
    static let skipTaglikeNotation = ["@IF"]

    var name: String
    var address: (UInt, UInt)?
    var namespaceCallable: String?

    var file: [String]
    var assemblyOutlet = [String]()

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

    func tags() {
        var tagAmount = 0

        for tag in file.prefix(while: { $0.hasPrefix("@") }) {
            var tagComponents = tag.components(separatedBy: .whitespaces)
            let identifier = tagComponents.removeFirst()

            if MemoryComponent.validTags.contains(identifier) {
                print("\(name) \(identifier)")
                tagAmount += 1
                continue
            }

            if !MemoryComponent.skipTaglikeNotation.contains(identifier) {
                CLIStateController.terminate("Parse error: invalid tag '\(identifier)' in file '\(name)'")
            } else {
                break
            }
        }

        file.removeFirst(tagAmount)
    }
}
