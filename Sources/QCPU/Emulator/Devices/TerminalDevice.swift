//
//  TerminalDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/04/2022.
//

class TerminalDevice: Device {

    var instructionSize = 2

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
        if instruction == 0 {
            emulator.outputStream.append(String())
            return
        }

        if let ascii = UnicodeScalar(emulator.accumulator) {
            let asciiString = String(ascii)
            emulator.outputStream.count > 0 ?
                emulator.outputStream[emulator.outputStream.count - 1].append(asciiString) :
                emulator.outputStream.append(asciiString)
        }
    }

    func load(instruction: Int) {
        emulator.accumulator = characters.count > 0 ?
            characters.removeFirst() :
            0
    }
}
