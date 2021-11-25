//
//  String.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 15/11/2021.
//

extension Array where Element == String {
    func byNewlines() -> String {
        self.joined(separator: "\n")
    }
}

extension Array where Element: MemoryComponent {
    var insertable: [MemoryComponent] {
        self.filter { $0.header != nil || $0.enumeration != nil }
    }
}
