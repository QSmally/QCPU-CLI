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

    func padding(toLength length: Int, withPad pad: String = " ") -> String {
        padding(toLength: length, withPad: pad, startingAt: 0)
    }

    func leftPadding(toLength length: Int, withPad pad: String = " ") -> String {
        if count < length {
            let repeatedString = String()
                .padding(toLength: length - count, withPad: pad)
            return String(repeatedString).appending(self)
        } else {
            return String(suffix(length))
        }
    }
}
