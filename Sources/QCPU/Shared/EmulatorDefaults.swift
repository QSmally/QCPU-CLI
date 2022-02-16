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

    var ports: [Port]?
    var ports_addressSize: Int?
    var ports_generateClass: Bool?

}
