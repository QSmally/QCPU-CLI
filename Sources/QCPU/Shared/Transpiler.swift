//
//  Transpiler.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

final class Transpiler {

    static let validTags = [
        "@PAGE", "@HEADER", "@ADDRESSABLE", "@OVERFLOWABLE",
        "@DECLARE", "@ENUM", "@END"]
    static let indentedTagNotations = ["@ENUM"]
    static let breakTaglike = ["@IF"]
    static var compileTags = breakTaglike + ["@END"]

    unowned var memoryComponent: MemoryComponent

    var tagAmount = 0
    var lineIteratorCount: UInt = 0
    var indentations = [IndentationController]()

    var isCodeBlock: Bool {
        memoryComponent.address != nil && memoryComponent.header == nil
    }

    init(_ memoryComponent: MemoryComponent) {
        self.memoryComponent = memoryComponent
    }
}
