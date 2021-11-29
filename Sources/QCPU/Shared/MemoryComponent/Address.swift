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

        init(segment: UInt, page: UInt, line: UInt = 0) {
            self.segment = segment
            self.page = page
            self.line = line
        }

        func parse(mode: String) -> String {
            switch mode {
                case "":  return String(line)
                case "-": return String((page << 5) + line)
                case "+": return String(segment)
                default:
                    CLIStateController.terminate("Fatal error: unrecognised address mode '\(mode)'")
            }
        }
    }
}
