//
//  Transpile.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension Transpiler {

    static var aliases: [String: (instruction: MemoryComponent.Instruction, operand: Int)] = [
        "nop": (instruction: .add, operand: 0)
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
                    Int.parse(fromString: instructionComponents.first!) :
                    nil

                memoryComponent.binary.dictionary[index]?.transpile(
                    represents: instruction,
                    operand: operand ?? 0)

                if memoryComponent.binary.dictionary[index]?.representsCompiled?.operand ?? -1 > 0 && operand == nil {
                    CLIStateController.terminate("Parse error: missing operand for instruction '\(instructionString)'")
                }

                continue
            }

            if let immediate = mergeIntParser(fromString: immutableStatement.representativeString) {
                memoryComponent.binary.dictionary[index]?.transpile(
                    value: immediate,
                    botherCompileInstruction: false)
                continue
            }

            if let alias = Transpiler.aliases[instructionString] {
                memoryComponent.binary.dictionary[index]?.transpile(
                    represents: alias.instruction,
                    operand: alias.operand)
                continue
            }

            CLIStateController.terminate("Parse error: invalid instruction, immediate or alias '\(firstComponent)'")
        }
    }

    private func mergeIntParser(fromString representativeString: String) -> Int? {
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
