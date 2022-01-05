//
//  CompiledStatement.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension MemoryComponent {
    class Statement {

        enum Instruction: Int, CaseIterable {
            case nop = 0b0_0000_000,
                 cpl = 0b0_0000_001,
                 ppl = 0b0_0000_010,
                 msa = 0b0_0000_011,
                 mda = 0b0_0000_100,
                 nta = 0b0_0000_101,
                 dfu = 0b0_0000_110,
                 pcm = 0b0_0000_111,
                 cpn = 0b0_0001_000,
                 cnd = 0b0_0010_000,
                 imm = 0b0_0011_000,
                 rst = 0b0_0100_000,
                 ast = 0b0_0101_000,
                 inc = 0b0_0110_000,
                 dec = 0b0_0111_000,
                 neg = 0b0_1000_000,
                 rsh = 0b0_1001_000,
                 add = 0b0_1010_000,
                 sub = 0b0_1011_000,
                 ior = 0b0_1100_000,
                 and = 0b0_1101_000,
                 xor = 0b0_1110_000,
                 imp = 0b0_1111_000,
                 bsl = 0b1_0000_000,
                 bpl = 0b1_0001_000,
                 bsr = 0b1_0010_000,
                 bpr = 0b1_0011_000,
                 pst = 0b0_0100_000,
                 pld = 0b0_0101_000,
                 cps = 0b1_0110_000,
                 pps = 0b1_0111_000,
                 ent = 0b1_1000_000,
                 jmp = 0b1_1100_000,
                 brh = 0b1_1101_000,
                 mst = 0b1_1110_000,
                 mld = 0b1_1111_000

            var operand: Int {
                switch self {
                    case .ent:
                        return 5
                    case .pst, .pld, .cpn, .cnd, .imm, .rst,
                         .ast, .inc, .dec, .neg, .rsh, .add,
                         .sub, .ior, .and, .xor, .imp, .bsl,
                         .bpl, .bsr, .bpr, .cps, .pps, .jmp,
                         .brh, .mst, .mld:
                        return 3
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

            func amountSecondaryBytes(operand: Int) -> Int {
                if [.cps, .pps].contains(self) && operand == 0 {
                    return 1
                }

                return [.msa, .imm, .pst, .pld, .jmp, .brh, .mst, .mld].contains(self) ?
                    1 :
                    0
            }
        }

        var value: Int
        var representsCompiled: Instruction!
        var renderComponent: Bool

        lazy var operand: Int = {
            switch representsCompiled.operand {
                case 5: return value & 0x1F
                case 3: return value & 0x07
                default:
                    return 0
            }
        }()

        lazy var formatted: String = {
            if !renderComponent {
                return String(value, radix: 2)
                    .leftPadding(toLength: 8, withPad: "0")
            }

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
            self.renderComponent = true
        }

        init(value: Int, botherCompiling: Bool = true) {
            self.value = value
            self.representsCompiled = botherCompiling ?
                Instruction.allCases.first { $0.rawValue >> $0.operand == value >> $0.operand } :
                nil
            self.renderComponent = botherCompiling
        }
    }
}
