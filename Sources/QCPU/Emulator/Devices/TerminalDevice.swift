//
//  TerminalDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/04/2022.
//

class TerminalDevice: Device {

    var instructionSize = 3

    unowned var emulator: EmulatorStateController
    var profile: EmulatorDefaults.Port
    var startAddress: Int

    var characters = [Int]()

    required init(emulator: EmulatorStateController, profile: EmulatorDefaults.Port, startAddress: Int) {
        self.emulator = emulator
        self.profile = profile
        self.startAddress = startAddress
    }

    func execute(instruction: Int) {
        switch instruction {
            case 0:
                emulator.outputStream.append(String())

            case 1:
                if let ascii = UnicodeScalar(emulator.accumulator) {
                    let asciiString = String(ascii)
                    emulator.outputStream.count > 0 ?
                        emulator.outputStream[emulator.outputStream.count - 1].append(asciiString) :
                        emulator.outputStream.append(asciiString)
                }

            case 2:
                emulator.accumulator = characters.count > 0 ?
                    characters.removeFirst() :
                    0

            default:
                break
        }
    }
}
