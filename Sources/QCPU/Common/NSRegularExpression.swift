//
//  NSRegularExpression.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

import Foundation

extension NSRegularExpression {
    func match(_ inputString: String, group: Int = 0) -> String? {
        let range = NSRange(location: 0, length: inputString.utf16.count)
        let textCheckingResult = firstMatch(in: inputString, options: [], range: range)

        if let textCheckingResult = textCheckingResult {
            let bridgedNSRange = Range(textCheckingResult.range(at: group), in: inputString)!
            return String(inputString[bridgedNSRange])
        } else {
            return nil
        }
    }
}
