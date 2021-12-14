//
//  String.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 15/11/2021.
//

extension Array {
    mutating func removeCopy() -> Self {
        let copyArray = self
        removeAll(keepingCapacity: true)
        return copyArray
    }

    mutating func pop() -> Element {
        popLast()!
    }

    func inserted(_ element: Element, at index: Int? = nil) -> Self {
        var copyArray = self
        copyArray.insert(element, at: index ?? count)
        return copyArray
    }

    func inserted(_ elements: [Element]) -> Self {
        var copyArray = self
        copyArray.append(contentsOf: elements)
        return copyArray
    }
}

extension Array where Element == String {
    func byNewlines() -> String {
        joined(separator: "\n")
    }
}
