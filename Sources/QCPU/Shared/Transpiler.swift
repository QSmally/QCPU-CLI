//
//  Transpiler.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

final class Transpiler {

    static let validTags = [
        "@PAGE", "@HEADER", "@ADDRESSABLE", "@OVERFLOWABLE",
        "@MAKEPAGE", "@DECLARE", "@ENUM", "@END"]
    static let indentedTagNotations = ["@ENUM"]
    static let breakTaglike = ["@IF"]
    static var compileTags = breakTaglike + ["@END"]

    unowned var memoryComponent: MemoryComponent

    var tagAmount = 0
    var layers = [IndentationLayer]()
    var pagesGenerated = [MemoryComponent]()

    var isCodeBlock: Bool {
        memoryComponent.address != nil && memoryComponent.header == nil
    }

    init(_ memoryComponent: MemoryComponent) {
        self.memoryComponent = memoryComponent
    }
}
