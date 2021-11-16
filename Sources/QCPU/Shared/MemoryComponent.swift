//
//  MemoryComponent.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/11/2021.
//

class MemoryComponent {

    var name: String?
    var address: (UInt, UInt)
    var file: [String]

    var assembledOutput = [String]()

    init(_ address: (UInt, UInt), instructions: [String]) {
        self.address = address
        self.file = instructions
    }
}
