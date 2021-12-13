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

    func inserted(_ element: Element, at index: Int) -> Self {
        var copyArray = self
        copyArray.insert(element, at: index)
        return copyArray
    }
}

extension Array where Element == String {
    func byNewlines() -> String {
        joined(separator: "\n")
    }
}
