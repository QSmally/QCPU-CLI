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
