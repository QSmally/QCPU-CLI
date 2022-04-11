//
//  ASCIIDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/03/2022.
//

class GenericASCIIDevice: Device {

    var instructionSize = 2

    unowned var emulator: EmulatorStateController
    var profile: EmulatorDefaults.Port
    var startAddress: Int

    required init(emulator: EmulatorStateController, profile: EmulatorDefaults.Port, startAddress: Int) {
        self.emulator = emulator
        self.profile = profile
        self.startAddress = startAddress
    }

    func execute(instruction: Int) {
        switch instruction {
            case 0:
                if let ascii = UnicodeScalar(emulator.accumulator) {
                    emulator.outputStream.append("\(instruction): \(ascii)")
                }

            case 1:
                emulator.clock?.suspend()
                emulator.accumulator = Int(readLine(strippingNewline: true) ?? "0") ?? 0
                emulator.clock?.resume()

            default:
                break
        }
    }
}
