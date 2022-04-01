//
//  FileHandle.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/04/2022.
//

import Foundation

extension FileHandle {
    static func getch() -> UInt8 {
        let handle = FileHandle.standardInput
        let term = handle.rawEnable()

        defer {
            handle.restore(originalTerm: term)
        }

        var byte: UInt8 = 0
        Darwin.read(handle.fileDescriptor, &byte, 1)
        return byte
    }

    func rawEnable() -> termios {
        var raw = termios()
        tcgetattr(fileDescriptor, &raw)

        let original = raw
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        tcsetattr(fileDescriptor, TCSADRAIN, &raw)

        return original
    }

    func restore(originalTerm: termios) {
        var term = originalTerm
        tcsetattr(fileDescriptor, TCSADRAIN, &term)
    }
}
