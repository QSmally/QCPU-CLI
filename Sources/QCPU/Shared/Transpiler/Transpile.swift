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

            if let immediate = parseIntegerOffset(fromString: immutableStatement.representativeString) {
                memoryComponent.binary.dictionary[index]?.transpile(
                    value: immediate,
                    botherCompileInstruction: false)
                continue
            }

            if let alias = Transpiler.aliases[instructionString] {
                memoryComponent.binary.dictionary[index]?.transpile(
                    represents: alias,
                    operand: 0)
                continue
            }

            if instructionString.uppercased() == "EMPTY" {
                memoryComponent.binary.dictionary.removeValue(forKey: index)
                continue
            }

            CLIStateController.terminate("Parse error: invalid instruction, immediate or alias '\(firstComponent)'")
        }
    }

    private func parseIntegerOffset(fromString representativeString: String) -> Int? {
        let optionalArray = representativeString
            .components(separatedBy: .whitespaces)
            .map { Int.parse(fromString: $0) }
        guard optionalArray.filter({ $0 == nil }).count == 0 else {
            return nil
        }

        return optionalArray
            .reduce(0) { $0 + $1! }
    }
}
