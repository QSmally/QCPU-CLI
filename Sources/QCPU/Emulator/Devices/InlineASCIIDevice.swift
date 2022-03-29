//
//  InlineASCIIDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 29/03/2022.
//

class InlineASCIIDevice: Device {

    var instructionSize = 1

    unowned var emulator: EmulatorStateController
    var profile: EmulatorDefaults.Port
    var startAddress: Int

    required init(emulator: EmulatorStateController, profile: EmulatorDefaults.Port, startAddress: Int) {
        self.emulator = emulator
        self.profile = profile
        self.startAddress = startAddress
    }

    func store(instruction: Int) {
        if let ascii = UnicodeScalar(emulator.accumulator) {
            if emulator.outputStream.count == 0 { load(instruction: 0) }
            emulator.outputStream[emulator.outputStream.count - 1] += String(ascii)
        }
    }

    func load(instruction: Int) {
        emulator.outputStream.append(String())
    }
}
