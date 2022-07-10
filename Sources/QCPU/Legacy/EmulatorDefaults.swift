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

        var Class: Device.Type {
            switch type {
                case .integerInput:  return InputIntegerDevice.self
                case .integerOutput: return OutputIntegerDevice.self
                case .asciiInput:    return InputASCIIDevice.self
                case .asciiOutput:   return OutputASCIIDevice.self
                case .terminal:      return TerminalDevice.self
                case .timer:         return TimerDevice.self
                case .multiply:      return MultiplyDevice.self
                case .divide:        return DivideDevice.self
                case .modulo:        return ModuloDevice.self
                default:
                    CLIStateController.terminate("Fatal error: unimplemented port '\(type)'")
            }
        }

        func generateClass(emulator: EmulatorStateController, startAddress: Int) -> Device {
            Class.init(
                emulator: emulator,
                profile: self,
                startAddress: startAddress)
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
