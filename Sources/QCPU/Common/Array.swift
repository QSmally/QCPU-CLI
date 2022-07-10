//
//  String.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 15/11/2021.
//

extension Array {
    func inserted(_ element: Element, at index: Int? = nil) -> Self {
        var arrayCopy = self
        arrayCopy.insert(element, at: index ?? count)
        return arrayCopy
    }

    func inserted(_ elements: [Element]) -> Self {
        var arrayCopy = self
        arrayCopy.append(contentsOf: elements)
        return arrayCopy
    }

    mutating func removeCopyEnumerated() -> Self {
        let copyArray = self
        removeAll(keepingCapacity: true)
        return copyArray
    }
}

extension Array where Element == String {
    func byNewlines() -> String {
        joined(separator: "\n")
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
