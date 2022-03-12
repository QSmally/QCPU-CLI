//
//  CountableClosedRange.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 12/03/2022.
//

extension Dictionary where Key == CountableClosedRange<Int> {
    subscript(address address: Int) -> Value? {
        for key in keys {
            if key ~= address {
                return self[key]
            }
        }

        return nil
    }
}
