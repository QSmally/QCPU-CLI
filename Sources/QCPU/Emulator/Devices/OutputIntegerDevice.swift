//
//  OutputIntegerDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 11/04/2022.
//

class OutputIntegerDevice: Device {

    var instructionSize = 1

    unowned var emulator: EmulatorStateController
    var profile: EmulatorDefaults.Port
    var startAddress: Int

    required init(emulator: EmulatorStateController, profile: EmulatorDefaults.Port, startAddress: Int) {
        self.emulator = emulator
        self.profile = profile
        self.startAddress = startAddress
    }

    func execute(instruction: Int) {
        emulator.outputStream.append("\(instruction): \(emulator.accumulator)")
    }
}
