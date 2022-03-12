//
//  EmulatorDefaults.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/02/2022.
//

import Foundation

struct EmulatorDefaults: Codable {

    enum DeviceType: String, Codable {
        case io,
             multiply,
             divide,
             modulo
    }

    struct Port: Codable {

        var name: String
        var type: DeviceType

        var address: Int?
        var loadPenalty: Int?
        var generateNameClass: Bool?

        func generateClass(emulator: EmulatorStateController, startAddress: Int) -> Device {
            switch type {
                case .io: return InputOutputDevice(
                    emulator: emulator,
                    profile: self,
                    startAddress: startAddress)
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

    func store(instruction: Int)
    func load(instruction: Int)
}
