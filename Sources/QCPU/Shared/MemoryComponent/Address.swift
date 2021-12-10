//
//  Address.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 26/11/2021.
//

extension MemoryComponent {
    struct Address {

        let segment: UInt
        let page: UInt
        let line: UInt

        enum Mode {
            case segment,
                 page,
                 line
        }

        init(segment: UInt, page: UInt, line: UInt = 0) {
            self.segment = segment
            self.page = page
            self.line = line
        }

        init(segment: Int, page: Int, line: Int = 0) {
            self.segment = UInt(segment)
            self.page = UInt(page)
            self.line = UInt(line)
        }

        init(upper: Int, lower: Int) {
            self.segment = UInt(upper)
            self.page = UInt(lower >> 5)
            self.line = UInt(lower & 0x1F)
        }

        func equals(to address: Address, basedOn mode: Mode = .line) -> Bool {
            switch mode {
                case .segment:
                    return segment == address.segment
                case .page:
                    return segment == address.segment &&
                        page == address.page
                case .line:
                    return segment == address.segment &&
                        page == address.page &&
                        line == address.line
            }
        }

        func parse(mode: String) -> String {
            switch mode {
                case "":  return String(line)
                case "-": return String((page << 5) | line)
                case "+": return String(segment)
                default:
                    CLIStateController.terminate("Fatal error: unrecognised address mode '\(mode)'")
            }
        }
    }
}
