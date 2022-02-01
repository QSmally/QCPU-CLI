//
//  Transpile.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension Transpiler {
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

            if let immediate = Int.parse(fromString: firstComponent) {
                memoryComponent.binary.dictionary[index]?.transpile(
                    value: immediate,
                    botherCompileInstruction: false)
                continue
            }

            CLIStateController.terminate("Parse error: invalid instruction or immediate '\(firstComponent)'")
        }
    }
}
