//
//  Address.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 26/11/2021.
//

extension MemoryComponent {
    struct Address {

        let segment: Int
        let page: Int
        let line: Int

        var bitfield: String {
             "\(segment)-\(page)"
        }

        enum Mode {
            case segment,
                 page,
                 line
        }

        init(segment: Int, page: Int, line: Int = 0) {
            self.segment = segment
            self.page = page
            self.line = line
        }

        init(upper: Int, lower: Int) {
            self.segment = upper
            self.page = lower >> 5
            self.line = lower & 0x1F
        }

        func equals(toSegment address: Address) -> Bool {
            segment == address.segment
        }

        func equals(toPage address: Address) -> Bool {
            segment == address.segment && page == address.page
        }

        func parse(mode: String) -> String {
            switch mode {
                case "": return String((page << 5) | line)
                case "+": return String(segment)
                default:
                    CLIStateController.terminate("Fatal error: unrecognised address mode '\(mode)'")
            }
        }
    }
}
