//
//  Compile.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension Transpiler {
    func binary() {
        for statement in memoryComponent.file {
            var instructionComponents = statement.components(separatedBy: .whitespaces)
            let firstComponent = instructionComponents.removeFirst()
            let instructionString = firstComponent.lowercased()

            if let instruction = MemoryComponent.CompiledStatement.Instruction(rawValue: instructionString) {
                if [.word].contains(instruction) {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): reserved instruction '\(instructionString)'")
                }

                if instructionComponents.count > 1 && instruction.binary.count == 8 {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): instruction '\(instructionString)' cannot have an operand")
                }

                let operand = instructionComponents.count > 1 ?
                    integer(instructionComponents[1]) :
                    nil
                let instructionStatement = MemoryComponent.CompiledStatement(
                    instruction: instruction,
                    operand: operand)

                memoryComponent.compiled.append(instructionStatement)
                continue
            }

            if let immediate = integer(firstComponent) {
                let immediateStatement = MemoryComponent.CompiledStatement(
                    instruction: .word,
                    operand: immediate)
                memoryComponent.compiled.append(immediateStatement)
                continue
            }

            CLIStateController.terminate("Parse error (\(memoryComponent.name)): invalid instruction or immediate '\(instructionString)'")
        }
    }

    private func integer(_ representativeString: String) -> Int? {
        if let negativeSymbol = Expressions.integer.match(representativeString, group: 1),
           let base = Expressions.integer.match(representativeString, group: 2),
           let integer = Expressions.integer.match(representativeString, group: 3) {
            guard let radix = base.radix else {
                CLIStateController.terminate("Parse error (\(memoryComponent.name)): invalid base '\(base)'")
            }

            guard let immediate = Int(integer, radix: radix) else {
                CLIStateController.terminate("Parse error (\(memoryComponent.name)): could not parse '\(integer)' as base \(radix)")
            }

            return negativeSymbol == "-" ?
                -immediate :
                immediate
        } else {
            return nil
        }
    }
}
