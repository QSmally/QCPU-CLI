//
//  CompiledStatement.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension MemoryComponent {
    struct CompiledStatement {

        enum Instruction: String {
            case word,
                 nop

            var binary: String {
                switch self {
                    case .nop: return "00000"
                    default:
                        CLIStateController.terminate("Fatal error: '\(rawValue)' does not have a binary representative value")
                }
            }
        }

        var display: String {
            switch instruction {
                case .word:
                    return String(operand!)
                default:
                    return operand == nil ?
                        instruction.rawValue :
                        "\(instruction.rawValue) \(operand!)"
            }
        }

        let instruction: Instruction
        let operand: Int8?
    }
}
