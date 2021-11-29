//
//  Expressions.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

import Foundation

enum Expressions {
    static let function = try! NSRegularExpression(pattern: #"%([a-zA-Z0-9_\.]+\s?.*)"#)
    static let flag     = try! NSRegularExpression(pattern: #"#(!?\w+)"#)
    static let tag      = try! NSRegularExpression(pattern: #"@([a-zA-Z0-9_\.]+)"#)
    static let label    = try! NSRegularExpression(pattern: #"^\.(&?)([a-zA-Z0-9_]+):$"#)
    static let address  = try! NSRegularExpression(pattern: #"\.([a-zA-Z0-9_]+)([-+]?)"#)
}
