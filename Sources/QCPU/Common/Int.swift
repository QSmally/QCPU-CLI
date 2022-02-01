//
//  Int.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/02/2022.
//

extension Int {
    static func parse(fromString representativeString: String) -> Int? {
        if let negativeSymbol = Expressions.integer.match(representativeString, group: 1),
           let base = Expressions.integer.match(representativeString, group: 2),
           let integer = Expressions.integer.match(representativeString, group: 3) {
            guard let radix = base.radix else {
                CLIStateController.terminate("Parse error: invalid base '\(base)'")
            }

            guard let immediate = Int(integer, radix: radix) else {
                CLIStateController.terminate("Parse error: could not parse '\(integer)' as base \(radix)")
            }

            return negativeSymbol == "-" ?
                -immediate :
                immediate
        }

        return nil
    }
}
