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
    var enums = [String: [String: String]]()
    var declarations = [String: String]()

    var purpose: Purpose = .application
    var representativeStrings: [String]
    var binary = MemoryObject<Statement>()
    lazy var transpiler = Transpiler(self)

    enum Purpose {
        case application,
             extended,
             reserved
    }

    struct MemoryObject<Element> {
        
        var pointer = 0
        var dictionary = [Int: Element]()
        
        var size: Int {
            dictionary.count
        }
        
        subscript(_ pointer: Int) -> Element? {
            get { dictionary[pointer] }
            set(value) { dictionary[pointer] = value }
        }
        
        mutating func append(_ element: Element) {
            dictionary[pointer] = element
            pointer += 1
        }
    }

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
        clonedMemoryComponent.declarations = declarations
        clonedMemoryComponent.binary = binary

        return clonedMemoryComponent
    }
}
