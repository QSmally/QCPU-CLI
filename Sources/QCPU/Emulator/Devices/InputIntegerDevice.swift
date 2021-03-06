//
//  InputIntegerDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 07/03/2022.
//

class InputIntegerDevice: Device {

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
        emulator.clock?.suspend()
        emulator.accumulator = Int(readLine(strippingNewline: true) ?? "0") ?? 0
        emulator.clock?.resume()
    }
}
