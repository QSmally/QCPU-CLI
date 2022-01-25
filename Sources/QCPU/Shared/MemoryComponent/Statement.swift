//
//  CompiledStatement.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension MemoryComponent {
    enum Instruction: Int, CaseIterable {
        case nop = 0b0_0000_000,
             ppi = 0b0_0000_001,
             ppl = 0b0_0000_010,
             cpp = 0b0_0000_011,
             cpl = 0b0_0000_100,
             /* 0b0_0000_101 empty */
             nta = 0b0_0000_110,
             pcm = 0b0_0000_111,
             // General
             cnd = 0b0_0001_000,
             imm = 0b0_0010_000,
             pps = 0b0_0011_000,
             // Register management
             xch = 0b0_0100_000,
             rst = 0b0_0101_000,
             ast = 0b0_0110_000,
             // Arithmetic
             inc = 0b0_0111_000,
             dec = 0b0_1000_000,
             neg = 0b0_1001_000,
             rsh = 0b0_1010_000,
             add = 0b0_1011_000,
             sub = 0b0_1100_000,
             // Logic
             ior = 0b0_1101_000,
             and = 0b0_1110_000,
             xor = 0b0_1111_000,
             // Barrel shifter
             bsl = 0b1_0000_000,
             bpl = 0b1_0001_000,
             bsr = 0b1_0010_000,
             bpr = 0b1_0011_000,
             // Kernel
             ent = 0b1_010_0000,
             mmu = 0b1_011_0000,
             prf = 0b1_1000_000,
             // Ports
             pst = 0b1_1001_000,
             pld = 0b1_1010_000,
             // Memory management
             jmp = 0b1_1011_000,
             cal = 0b1_1100_000,
             brh = 0b1_1101_000,
             mst = 0b1_1110_000,
             mld = 0b1_1111_000

        var operand: Int {
            switch self {
                case .ent, .mmu:
                    return 4
                case .cnd, .imm, .xch, .rst, .ast, .inc,
                        .dec, .neg, .rsh, .add, .sub, .ior,
                        .and, .xor, .bsl, .bpl, .bsr, .bpr,
                        .prf, .pps, .pst, .pld, .jmp, .cal,
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

        var hasSecondaryByte: Bool {
            [.ppi, .imm, .pst, .pld, .jmp, .cal, .brh, .mst, .mld].contains(self)
        }
    }

    class Statement {

        var rawStatement: String
        var value: Int!
        var representsCompiled: Instruction?

        var renderStatement = false

        lazy var operand: Int = {
            switch representsCompiled?.operand {
                case 4: return value & 0b0000_1111
                case 3: return value & 0b0000_0111
                default:
                    return 0
            }
        }()

        lazy var formatted: String = {
            if !renderStatement {
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

        init(fromString rawStatement: String) {
            self.rawStatement = rawStatement
        }

        func instruction(represents instruction: Instruction, operand: Int) {
            self.value = instruction.rawValue | operand
            self.representsCompiled = instruction
            self.renderStatement = true
        }

        func instruction(value: Int, botherCompileInstruction: Bool = true) {
            self.value = value
            self.representsCompiled = botherCompileInstruction ?
                Instruction.allCases.first { $0.rawValue >> $0.operand == value >> $0.operand } :
                nil
            self.renderStatement = botherCompileInstruction
        }
    }
}
