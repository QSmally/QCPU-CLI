//
//  RandomInsertArray.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 24/01/2022.
//

struct RandomInsertArray<Element> {

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
