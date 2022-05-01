//
//  EmulatorDefaults.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/02/2022.
//

import Foundation

struct EmulatorDefaults: Codable {

    enum DeviceType: String, Codable {
        case integerInput,
             integerOutput,
             asciiInput,
             asciiOutput,
             terminal,
             timer,
             multiply,
             divide,
             modulo,
             root
    }

    struct Port: Codable {

        var name: String
        var type: DeviceType

        var address: Int?
        var loadPenalty: Int?
        var generateNameClass: Bool?

        func generateClass(emulator: EmulatorStateController, startAddress: Int) -> Device {
            switch type {
                case .integerInput:  return InputIntegerDevice(emulator: emulator, profile: self, startAddress: startAddress)
                case .integerOutput: return OutputIntegerDevice(emulator: emulator, profile: self, startAddress: startAddress)
                case .asciiInput:    return InputASCIIDevice(emulator: emulator, profile: self, startAddress: startAddress)
                case .asciiOutput:   return OutputASCIIDevice(emulator: emulator, profile: self, startAddress: startAddress)
                case .terminal:      return TerminalDevice(emulator: emulator, profile: self, startAddress: startAddress)
                case .timer:         return TimerDevice(emulator: emulator, profile: self, startAddress: startAddress)
                case .multiply:      return MultiplyDevice(emulator: emulator, profile: self, startAddress: startAddress)
                case .divide:        return DivideDevice(emulator: emulator, profile: self, startAddress: startAddress)
                case .modulo:        return ModuloDevice(emulator: emulator, profile: self, startAddress: startAddress)
                default:
                    CLIStateController.terminate("Fatal error: unimplemented port '\(type)'")
            }
        }
    }

    var speed: Double?
    var burstSize: Int?
    var maxTime: Int?

    var ports: [Port]?
    var ports_generateClass: Bool?

    var kernel_entryCall: [Int]?
    var kernel_mapping: [Int: [Int]]?

}

protocol Device {

    var instructionSize: Int { get set }

    var emulator: EmulatorStateController { get }
    var profile: EmulatorDefaults.Port { get }
    var startAddress: Int { get }

    init(
        emulator: EmulatorStateController,
        profile: EmulatorDefaults.Port,
        startAddress: Int)

    func execute(instruction: Int)
}
