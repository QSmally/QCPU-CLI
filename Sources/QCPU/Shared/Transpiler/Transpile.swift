//
//  Transpile.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension Transpiler {

    static var aliases: [String: MemoryComponent.Instruction] = [
        "fwd": .rst,
        "clr": .ast,
        "nop": .add
    ]

    func transpile() {
        for (index, immutableStatement) in memoryComponent.binary.dictionary {
            var instructionComponents = immutableStatement.representativeString.components(separatedBy: .whitespaces)
            let firstComponent = instructionComponents.removeFirst()
            let instructionString = firstComponent.lowercased()

            if let instruction = MemoryComponent.Instruction(from: instructionString) {
                if instructionComponents.count > 0 && instruction.operand == 0 {
                    CLIStateController.terminate("Parse error: instruction '\(instructionString)' cannot have an operand")
                }

                let operand = instructionComponents.count > 0 ?
                    instruction.parseOperand(fromString: instructionComponents.first!) :
                    nil

                memoryComponent.binary.dictionary[index]?.transpile(
                    represents: instruction,
                    operand: operand ?? 0)

                if instruction.operand > 0 && operand == nil {
                    CLIStateController.terminate("Parse error: missing or invalid operand for instruction '\(instructionString)'")
                }

                continue
            }

            if let alias = Transpiler.aliases[instructionString] {
                memoryComponent.binary.dictionary[index]?.transpile(
                    represents: alias,
                    operand: 0)
                continue
            }

            if instructionString == "empty" {
                memoryComponent.binary.dictionary.removeValue(forKey: index)
                continue
            }

            if let immediate = parseIntegerOffset(fromString: immutableStatement.representativeString) {
                memoryComponent.binary.dictionary[index]?.transpile(
                    value: immediate,
                    botherCompileInstruction: false)
                continue
            }

            CLIStateController.terminate("Parse error: invalid instruction, constant or alias '\(firstComponent)'")
        }
    }

    private func parseIntegerOffset(fromString representativeString: String) -> Int? {
        var results = representativeString
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard results.count & 0x01 == 1 else {
            CLIStateController.terminate("Parse error: invalid amount of items in integer evaluation")
        }

        while results.count != 1 {
            let lhsString = results[0]
            let instructionString = results[1]
            let rhsString = results[2]

            results.removeFirst(3)

            guard let lhs = Int.parse(fromString: lhsString),
                  let rhs = Int.parse(fromString: rhsString) else {
                CLIStateController.terminate("Parse error: invalid integer-like '\(lhsString)' or '\(rhsString)'")
            }

            guard let instruction = parseInstruction(fromString: instructionString) else {
                CLIStateController.terminate("Parse error: invalid operator '\(instructionString)'")
            }

            let result = instruction(lhs, rhs)
            results.append(String(result))
        }

        guard let integerConstant = Int.parse(fromString: results.first!) else {
            return nil
        }

        return integerConstant
    }

    private func parseInstruction(fromString instruction: String) -> ((Int, Int) -> Int)? {
        switch instruction.lowercased() {
            case "add", "+": return { lhs, rhs in lhs + rhs }
            case "sub", "-": return { lhs, rhs in lhs - rhs }
            case "ior", "|": return { lhs, rhs in lhs | rhs }
            case "and", "&": return { lhs, rhs in lhs & rhs }
            case "xor", "*": return { lhs, rhs in lhs * rhs }
            default:
                return nil
        }
    }
}
