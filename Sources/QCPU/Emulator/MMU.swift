//
//  MMU.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

final class MMU {

    unowned var emulator: EmulatorStateController

    init(emulator: EmulatorStateController) {
        self.emulator = emulator
    }
}
