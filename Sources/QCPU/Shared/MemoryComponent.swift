//
//  MemoryComponent.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

import Foundation

final class MemoryComponent {

    var name: String
    var address: Address!
    var namespaceCallable: String?
    var overflowable = false

    var header: (
        name: String,
        parameters: [String])?
    var enumeration: (
        name: String,
        cases: [String: String])?
    var declarations = [String: String]()

    var representativeStrings: [String]
    var binary = RandomInsertArray<Statement>()
    lazy var transpiler = Transpiler(self)

    init(_ name: String, fromSource instructions: [String]) {
        self.name = name
        self.representativeStrings = instructions
    }

    static func create(url: String) -> MemoryComponent {
        let filename = URL(fileURLWithPath: url)
            .deletingPathExtension()
            .lastPathComponent
        let fileContents = try! String(contentsOfFile: url)
            .components(separatedBy: .newlines)
            .map { $0
                .components(separatedBy: "//").first!
                .components(separatedBy: ";").first! }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return MemoryComponent(filename, fromSource: fileContents)
    }

    static func empty(_ name: String = "untitled") -> MemoryComponent {
        MemoryComponent(name, fromSource: [])
    }

    static func empty(_ name: String = "untitled", atAddress address: Address) -> MemoryComponent {
        let memoryComponent = MemoryComponent(name, fromSource: [])
        memoryComponent.address = address

        return memoryComponent
    }

    func clone() -> MemoryComponent {
        let clonedMemoryComponent = MemoryComponent(name, fromSource: representativeStrings)
        clonedMemoryComponent.address = address
        clonedMemoryComponent.header = header
        clonedMemoryComponent.enumeration = enumeration
        clonedMemoryComponent.declarations = declarations
        clonedMemoryComponent.binary = binary

        return clonedMemoryComponent
    }
}

extension Array where Element == MemoryComponent {
    func locate(address: MemoryComponent.Address) -> MemoryComponent? {
        first { $0.address.equals(toPage: address) }
    }

    func index(ofAddress address: MemoryComponent.Address) -> Int? {
        firstIndex { $0.address.equals(toPage: address) }
    }

    mutating func insert(memoryComponent: MemoryComponent) {
        if let index = index(ofAddress: memoryComponent.address) {
            self[index] = memoryComponent
        } else {
            append(memoryComponent)
        }
    }
}
