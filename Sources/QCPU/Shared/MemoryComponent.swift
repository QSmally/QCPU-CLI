//
//  MemoryComponent.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

class MemoryComponent {

    var name: String
    var address: (UInt, UInt)?
    var namespaceCallable: String?

    var file: [String]
    var assembledOutput = [String]()

    init(_ name: String, fromSource instructions: [String]) {
        self.name = name
        self.file = instructions
    }
}
