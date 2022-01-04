//
//  Expressions.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

import Foundation

enum Expressions {
    static let function  = try! NSRegularExpression(pattern: #"%([a-zA-Z0-9_\.]+\s?.*)"#)
    static let condition = try! NSRegularExpression(pattern: #"#(!?[a-zA-Z]+)"#)
    static let marco     = try! NSRegularExpression(pattern: #"@([a-zA-Z0-9_\.\*]+)"#)
    static let label     = try! NSRegularExpression(pattern: #"^\.(&?)([a-zA-Z0-9_\.]+):$"#)
    static let address   = try! NSRegularExpression(pattern: #"\.([a-zA-Z0-9_\.]+)(\!?)([+]?)"#)
    static let integer   = try! NSRegularExpression(pattern: #"^(\-?)((?:0x|0b)?)([\dA-F]+)$"#)
    static let ascii     = try! NSRegularExpression(pattern: #"^\$(.+)$"#)
    static let flag      = try! NSRegularExpression(pattern: #"(!?)(.+)"#)
}

enum StylingGuidelines {

    case header,
         declaration

    static func validate(_ input: String, withSource expression: StylingGuidelines) {
        if regex(ofSource: expression).match(input) == nil {
            let prefix = "Style warning (\(input))"
            CLIStateController.newline("\(prefix): \(message(ofSource: expression))")
        }
    }

    static private func regex(ofSource expression: StylingGuidelines) -> NSRegularExpression {
        switch expression{
            case .header:      return try! NSRegularExpression(pattern: #"^[A-Z0-9]+$"#)
            case .declaration: return try! NSRegularExpression(pattern: #"^[a-z0-9_\.\*]+$"#)
        }
    }

    static private func message(ofSource expression: StylingGuidelines) -> String {
        switch expression {
            case .header:      return "a header should only contain capital letters, joined without spacing or underscores"
            case .declaration: return "declarations should be snake_cased and only have lowercase characters"
        }
    }
}
