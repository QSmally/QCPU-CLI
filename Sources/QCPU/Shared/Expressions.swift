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
    static let marco     = try! NSRegularExpression(pattern: #"@([a-zA-Z0-9_\.]+(?:\.{3})?)"#)
    static let label     = try! NSRegularExpression(pattern: #"^\.(&?)([a-zA-Z0-9_\.]+)((?:\((.*)\))?):$"#)
    static let address   = try! NSRegularExpression(pattern: #"\.([a-zA-Z0-9_\.]+)(\!?)([+]?)"#)
    static let integer   = try! NSRegularExpression(pattern: #"^(\-?)((?:0x|0b)?)([\dA-F]+)$"#)
    static let ascii     = try! NSRegularExpression(pattern: #"^\$(.+)$"#)
    static let flag      = try! NSRegularExpression(pattern: #"(!?)(.+)"#)

    static private let headerStyle      = try! NSRegularExpression(pattern: #"^[A-Z0-9]+$"#)
    static private let declarationStyle = try! NSRegularExpression(pattern: #"^[a-z0-9_\.]+(?:\.{3})?$"#)

    static func stylingGuideline(forHeader input: String) {
        if headerStyle.match(input) == nil {
            CLIStateController.newline("Style warning \(input): a header should only contain capital letters, joined without spacing or underscores")
        }
    }

    static func stylingGuideline(forDeclaration input: String) {
        if declarationStyle.match(input) == nil {
            CLIStateController.newline("Style warning \(input): declarations should be snake_cased and only have lowercase characters")
        }
    }
}
