//
//  CompiledStatement.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension MemoryComponent {
    class Statement {

        enum Instruction: Int, CaseIterable {
            case nop = 0b00000000,
                 spt = 0b00000001,
                 dss = 0b00000010,
                 dls = 0b00000011,
                 spl = 0b00000100,
                 nta = 0b00000110,
                 pcm = 0b00000111,
                 pst = 0b00001000,
                 pld = 0b00010000,
                 cpn = 0b00011000,
                 cnd = 0b00100000,
                 imm = 0b00101000,
                 rst = 0b00110000,
                 ast = 0b00111000,
                 inc = 0b01000000,
                 dec = 0b01001000,
                 neg = 0b01010000,
                 rsh = 0b01011000,
                 add = 0b01100000,
                 sub = 0b01101000,
                 ent = 0b01110000,
                 pps = 0b01110001,
                 ppl = 0b01110010,
                 cps = 0b01110011,
                 cpl = 0b01110100,
                 dds = 0b01110101,
                 ddl = 0b01110110,
                 ibl = 0b01110111,
                 poi = 0b01111000,
                 ior = 0b10000000,
                 and = 0b10001000,
                 xor = 0b10010000,
                 imp = 0b10011000,
                 jmp = 0b10100000,
                 mst = 0b11000000,
                 mld = 0b11100000

            var operand: Int {
                switch self {
                    case .jmp, .mst, .mld:
                        return 5
                    case .pst, .pld, .cpn, .cnd, .imm, .rst,
                         .ast, .inc, .dec, .neg, .rsh, .add,
                         .sub, .poi, .ior, .and, .xor, .imp:
                        return 3
                    default:
                        return 0
                }
            }

            var amountSecondaryBytes: Int {
                switch self {
                    case .dds, .ddl, .ibl:
                        return 2
                    case .dss, .dls, .spl, .imm, .ent, .cps:
                        return 1
                    default:
                        return 0
                }
            }

            private static var cache = [String: Instruction]()

            init?(from representativeString: String) {
                if Instruction.cache.isEmpty {
                    let cases = Instruction.allCases.map { ("\($0)", $0) }
                    Instruction.cache = Dictionary(uniqueKeysWithValues: cases)
                }

                if let instruction = Instruction.cache[representativeString] {
                    self = instruction
                    return
                } else {
                    return nil
                }
            }
        }

        var value: Int
        var representsCompiled: Instruction!

        lazy var operand: Int = {
            switch representsCompiled.operand {
                case 5: return value & 0x1F
                case 3: return value & 0x07
                default:
                    return 0
            }
        }()

        lazy var formatted: String = {
            if let representsCompiled = representsCompiled {
                let instruction = String(describing: representsCompiled).uppercased()
                return representsCompiled.operand > 0 ?
                    "\(instruction) \(operand)" :
                    instruction
            } else {
                return String(value)
            }
        }()

        init(represents instruction: Instruction, operand: Int) {
            self.value = instruction.rawValue | operand
            self.representsCompiled = instruction
        }

        init(value: Int, botherCompiling: Bool = true) {
            self.value = value
            self.representsCompiled = botherCompiling ?
                Instruction.allCases.first { $0.rawValue >> $0.operand == value >> $0.operand } :
                nil
        }
    }
}
