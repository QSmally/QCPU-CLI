//
//  String.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

extension String {

    static var empty: String { "" }

    var radix: Int? {
        switch self {
            case "":   return 10
            case "0x": return 16
            case "0b": return 2
            default:
                return nil
        }
    }

    func padding(toLength length: Int) -> String {
        padding(toLength: length, withPad: " ", startingAt: 0)
    }
}
