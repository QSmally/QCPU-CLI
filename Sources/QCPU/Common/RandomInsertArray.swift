//
//  RandomInsertArray.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 24/01/2022.
//

struct RandomInsertArray<Element> {

    private var pointer = 0
    private(set) var dictionary = [Int: Element]()

    var size: Int {
        dictionary.count
    }

    init(contentsOf elements: [Element]) {
        append(contentsOf: elements)
    }

    subscript(_ pointer: Int) -> Element? {
        dictionary[pointer]
    }

    mutating func append(_ element: Element) {
        dictionary[pointer] = element
        pointer += 1
    }

    mutating func append(contentsOf elements: [Element]) {
        elements.forEach { append($0) }
    }

    func enumerated() -> Dictionary<Int, Element>.Iterator {
        dictionary.enumerated()
    }

    mutating func removeCopyEnumerated() -> Dictionary<Int, Element>.Iterator {
        var enumeration = dictionary.enumerated()
        dictionary.removeAll()
        return enumeration
    }
}
