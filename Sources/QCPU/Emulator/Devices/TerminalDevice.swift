//
//  TerminalDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/04/2022.
//

class TerminalDevice: Device {

    var instructionSize = 1

    unowned var emulator: EmulatorStateController
    var profile: EmulatorDefaults.Port
    var startAddress: Int

    var characters = [Int]()

    required init(emulator: EmulatorStateController, profile: EmulatorDefaults.Port, startAddress: Int) {
        self.emulator = emulator
        self.profile = profile
        self.startAddress = startAddress
    }

    func store(instruction: Int) {
        if let ascii = UnicodeScalar(emulator.accumulator) {
            emulator.outputStream.append("\(instruction): \(ascii)")
        }
    }

    func load(instruction: Int) {
        emulator.accumulator = characters.count > 0 ?
            characters.removeFirst() :
            0
    }
}
