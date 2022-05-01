//
//  TimerDevice.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/05/2022.
//

import Dispatch

class TimerDevice: Device {

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
        let milliseconds = DispatchTime.now().uptimeNanoseconds / 1_000_000
        emulator.accumulator = Int(milliseconds)
    }
}
