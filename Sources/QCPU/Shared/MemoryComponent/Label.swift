//
//  Label.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 26/11/2021.
//

extension MemoryComponent {
    struct Label {

        let id: String
        let address: Address
        let privacy: Privacy

        enum Privacy {
            case global,
                 segment,
                 page
        }
    }
}
