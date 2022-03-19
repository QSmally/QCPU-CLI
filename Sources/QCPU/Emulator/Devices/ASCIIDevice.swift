//
//  ASCIIDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/03/2022.
//

class ASCIIDevice: Device {

    var instructionSize = 1

    unowned var emulator: EmulatorStateController
    var profile: EmulatorDefaults.Port
    var startAddress: Int

    var buffer = [Character]()

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
        emulator.clock?.suspend()
        emulator.accumulator = Int(readLine(strippingNewline: true) ?? "0") ?? 0
        emulator.clock?.resume()
    }
}