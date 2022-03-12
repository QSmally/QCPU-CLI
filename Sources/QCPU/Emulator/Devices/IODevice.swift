//
//  IODevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 07/03/2022.
//

class InputOutputDevice: Device {

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
        emulator.outputStream.append("\(instruction): \(emulator.accumulator)")
    }

    func load(instruction: Int) {
        emulator.clock?.suspend()
        emulator.accumulator = Int(readLine(strippingNewline: true) ?? "0") ?? 0
        emulator.clock?.resume()
    }
}
