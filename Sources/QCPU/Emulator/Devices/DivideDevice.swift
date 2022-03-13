//
//  DivideDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 12/03/2022.
//

class DivideDevice: Device {

    var instructionSize = 1

    unowned let emulator: EmulatorStateController
    let profile: EmulatorDefaults.Port
    let startAddress: Int

    var firstArgument = 0

    required init(emulator: EmulatorStateController, profile: EmulatorDefaults.Port, startAddress: Int) {
        self.emulator = emulator
        self.profile = profile
        self.startAddress = startAddress
    }

    func store(instruction: Int) {
        firstArgument = emulator.accumulator
    }

    func load(instruction: Int) {
        let result = emulator.accumulator != 0 ?
            firstArgument / emulator.accumulator :
            0
        firstArgument = result
        emulator.accumulator = firstArgument
    }
}
