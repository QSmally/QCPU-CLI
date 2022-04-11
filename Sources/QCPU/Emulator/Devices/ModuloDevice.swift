//
//  ModuloDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 12/03/2022.
//

class ModuloDevice: Device {

    var instructionSize = 2

    unowned let emulator: EmulatorStateController
    let profile: EmulatorDefaults.Port
    let startAddress: Int

    var firstArgument = 0

    required init(emulator: EmulatorStateController, profile: EmulatorDefaults.Port, startAddress: Int) {
        self.emulator = emulator
        self.profile = profile
        self.startAddress = startAddress
    }

    func execute(instruction: Int) {
        switch instruction {
            case 0:
                firstArgument = emulator.accumulator

            case 1:
                let result = emulator.accumulator != 0 ?
                    firstArgument % emulator.accumulator :
                    0
                firstArgument = result
                emulator.accumulator = firstArgument

            default:
                break
        }
    }
}
