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
                 nop,
                 spt,
                 dss,
                 dls,
                 spl,
                 /* 0b00000101 missing */
                 nta,
                 pcm,
                 pst,
                 pld,
                 cpn,
                 cnd,
                 imm,
                 rst,
                 ast,
                 inc,
                 dec,
                 neg,
                 rsh,
                 add,
                 sub,
                 ent,
                 pps,
                 ppl,
                 cps,
                 cpl,
                 dds,
                 ddl,
                 ibl,
                 poi,
                 ior,
                 and,
                 xor,
                 imp,
                 jmp,
                 mst,
                 mld

            var binary: String {
                switch self {
                    case .nop: return "00000"
                    case .spt: return "00000001"
                    case .dss: return "00000010"
                    case .dls: return "00000011"
                    case .spl: return "00000100"
                        /* 0b00000101 missing */
                    case .nta: return "00000110"
                    case .pcm: return "00000111"
                    case .pst: return "00001"
                    case .pld: return "00010"
                    case .cpn: return "00011"
                    case .cnd: return "00100"
                    case .imm: return "00101"
                    case .rst: return "00110"
                    case .ast: return "00111"
                    case .inc: return "01000"
                    case .dec: return "01001"
                    case .neg: return "01010"
                    case .rsh: return "01011"
                    case .add: return "01100"
                    case .sub: return "01101"
                    case .ent: return "01110000"
                    case .pps: return "01110001"
                    case .ppl: return "01110010"
                    case .cps: return "01110011"
                    case .cpl: return "01110100"
                    case .dds: return "01110101"
                    case .ddl: return "01110110"
                    case .ibl: return "01110111"
                    case .poi: return "01111"
                    case .ior: return "10000"
                    case .and: return "10001"
                    case .xor: return "10010"
                    case .imp: return "10011"
                    case .jmp: return "101"
                    case .mst: return "110"
                    case .mld: return "111"
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
                    let formattedString = instruction.rawValue.uppercased()
                    return operand == nil ?
                        formattedString :
                        "\(formattedString) \(operand!)"
            }
        }

        var binary: String {
            switch instruction {
                case .word:
                    return String(operand!, radix: 2)
                default:
                    return operand == nil ?
                        instruction.binary :
                        instruction.binary + String(operand!, radix: 2)
            }
        }

        let instruction: Instruction
        let operand: Int?
    }
}
