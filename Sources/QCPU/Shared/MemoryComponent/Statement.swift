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
                 psp = 0b0_0000_001,
                 ppl = 0b0_0000_010,
                 cpp = 0b0_0000_011,
                 cpl = 0b0_0000_100,
                 cpa = 0b0_0000_101,
                 nta = 0b0_0000_110,
                 pcm = 0b0_0000_111,
                 // General
                 cnd = 0b0_0001_000,
                 imm = 0b0_0010_000,
                 // Register management
                 xch = 0b0_0011_000,
                 rst = 0b0_0100_000,
                 ast = 0b0_0101_000,
                 // Arithmetic
                 inc = 0b0_0110_000,
                 dec = 0b0_0111_000,
                 neg = 0b0_1000_000,
                 rsh = 0b0_1001_000,
                 add = 0b0_1010_000,
                 sub = 0b0_1011_000,
                 // Logic
                 ior = 0b0_1100_000,
                 and = 0b0_1101_000,
                 xor = 0b0_1110_000,
                 imp = 0b0_1111_000,
                 // Barrel shifter
                 bsl = 0b1_0000_000,
                 bpl = 0b1_0001_000,
                 bsr = 0b1_0010_000,
                 bpr = 0b1_0011_000,
                 // Kernel
                 ent = 0b1_010_0000,
                 mmu = 0b1_0110_000,
                 prf = 0b1_0111_000,
                 pps = 0b1_1000_000,
                 // Ports
                 pst = 0b1_1001_000,
                 pld = 0b1_1010_000,
                 // Memory management
                 jmp = 0b1_1011_000,
                 cts = 0b1_1100_000,
                 brh = 0b1_1101_000,
                 mst = 0b1_1110_000,
                 mld = 0b1_1111_000

            var operand: Int {
                switch self {
                    case .ent:
                        return 4
                    case .cnd, .imm, .xch, .rst, .ast, .inc,
                         .dec, .neg, .rsh, .add, .sub, .ior,
                         .and, .xor, .imp, .bsl, .bpl, .bsr,
                         .bpr, .mmu, .prf, .pps, .pst, .pld,
                         .jmp, .cts, .brh, .mst, .mld:
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

            var hasSecondaryByte: Bool {
                [.psp, .imm, .pst, .pld, .jmp, .cts, .brh, .mst, .mld].contains(self)
            }
        }

        var value: Int
        var representsCompiled: Instruction!
        var renderComponent: Bool

        lazy var operand: Int = {
            switch representsCompiled.operand {
                case 4: return value & 0x0F
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
