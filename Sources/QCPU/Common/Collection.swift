//
//  Collection.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 21/11/2021.
//

extension Collection where Indices.Iterator.Element == Index {
    subscript(optional index: Index) -> Iterator.Element? {
        return indices.contains(index) ?
            self[index] :
            nil
    }
}
