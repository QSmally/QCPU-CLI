//
//  InputOutput.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 07/03/2022.
//

struct InputOutputDevice: Device {

    unowned var emulator: EmulatorStateController

    func store(instruction: Int) {
        emulator.outputStream.append("\(instruction): \(emulator.accumulator)")
    }

    func load(instruction: Int) {
        emulator.clock?.suspend()
        emulator.accumulator = Int(readLine(strippingNewline: true) ?? "0") ?? 0
        emulator.clock?.resume()
    }
}
