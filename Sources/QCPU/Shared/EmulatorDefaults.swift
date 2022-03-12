//
//  EmulatorDefaults.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 16/02/2022.
//

import Foundation

struct EmulatorDefaults: Codable {

    enum DeviceType: Codable {
        case inputOutput,
             multiplier,
             divider,
             textScreen,
             graphicalScreen
    }

    struct Port: Codable {
        var name: String
        var address: Int
        var type: DeviceType
        var penalty: Int?
    }

    var speed: Double?
    var burstSize: Int?
    var maxTime: Int?

    var ports: [Port]?
    var ports_addressSize: Int?
    var ports_generateClass: Bool?

    var kernel_entryCall: [Int]?
    var kernel_mapping: [Int: [Int]]?

}

protocol Device {
    func store(instruction: Int)
    func load(instruction: Int)
}
