//
//  Expressions.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 25/11/2021.
//

import Foundation

enum Expressions {
    static let function = try! NSRegularExpression(pattern: #"%([a-zA-Z_\.]+)\s(\w)\s(.*)"#)
    static let tag = try! NSRegularExpression(pattern: #"@([a-zA-Z_\.]+)"#)
}