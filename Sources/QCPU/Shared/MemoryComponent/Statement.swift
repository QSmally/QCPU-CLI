//
//  CompiledStatement.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension MemoryComponent {
    enum Instruction: Int, CaseIterable {
        case ppi = 0b0_0000_000,
             ppl = 0b0_0000_001,
             ppk = 0b0_0000_010,
             cpi = 0b0_0000_011,
             cpl = 0b0_0000_100,
             cpa = 0b0_0000_101,
             pcm = 0b0_0000_110,
             nta = 0b0_0000_111,

             // General
             imm = 0b0_0001_000,
             pps = 0b0_0010_000,
             cps = 0b0_0011_000,

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
             brh = 0b1_1011_000,
             jmp = 0b1_1100_000,
             cal = 0b1_1101_000,
             mst = 0b1_1110_000,
             mld = 0b1_1111_000

        var operand: Int {
            switch self {
                case .ent, .mmu:
                    return 4
                case .imm, .pps, .cps, .xch, .rst, .ast,
                     .inc, .dec, .neg, .rsh, .add, .sub,
                     .ior, .and, .xor, .bsl, .bpl, .bsr,
                     .bpr, .prf, .pst, .pld, .brh, .jmp,
                     .cal, .mst, .mld:
                    return 3
                default:
                    return 0
            }
        }

        var hasSecondaryByte: Bool {
            [.ppi, .cpi, .imm, .pst, .pld, .brh, .jmp, .cal, .mst, .mld].contains(self)
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

        func parseOperand(fromString representativeString: String) -> Int? {
            switch representativeString.lowercased() {
                case "accumulator", "acc":
                    if [.imm, .pps, .cps, .inc, .dec, .neg,
                        .rsh].contains(self) {
                        return 0
                    }

                    [.jmp, .cal, .mst, .mld].contains(self) ?
                        CLIStateController.terminate("Parse error: instruction '\(self)' must use the 'FWD' (RST 0) instruction for 'accumulator' mapping") :
                        CLIStateController.terminate("Parse error: instruction '\(self)' does not support 'accumulator' mapping")

                case "zero", "zer":
                    if [.xch, .rsh, .ast, .add, .sub, .ior,
                        .and, .xor, .pst, .pld, .jmp, .cal,
                        .mst, .mld].contains(self) {
                        return 0
                    }

                    CLIStateController.terminate("Parse error: instruction '\(self)' does not support 'zero' mapping")

                case "forwarded", "fwd":
                    return 0

                default:
                    return Int.parse(fromString: representativeString)
            }
        }
    }

    class Statement {

        var representativeString: String
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

        init(fromString representativeString: String = "") {
            self.representativeString = representativeString
        }

        @discardableResult func transpile(represents instruction: Instruction, operand: Int) -> Statement {
            self.value = instruction.rawValue | operand
            self.representsCompiled = instruction
            self.renderStatement = true

            return self
        }

        @discardableResult func transpile(value: Int, botherCompileInstruction: Bool = true) -> Statement {
            self.value = value
            self.representsCompiled = botherCompileInstruction ?
                Instruction.allCases.first { $0.rawValue >> $0.operand == value >> $0.operand } :
                nil
            self.renderStatement = botherCompileInstruction

            return self
        }
    }
}
