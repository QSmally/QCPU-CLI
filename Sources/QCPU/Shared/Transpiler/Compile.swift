//
//  Compile.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

extension Transpiler {
    func binary() {
        for (index, statement) in memoryComponent.file.enumerated() {
            var instructionComponents = statement.components(separatedBy: .whitespaces)
            let firstComponent = instructionComponents.removeFirst()
            let instructionString = firstComponent.lowercased()

            if let instruction = MemoryComponent.Statement.Instruction(from: instructionString) {
                if instructionComponents.count > 0 && instruction.operand == 0 {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): instruction '\(instructionString)' cannot have an operand")
                }

                let operand = instructionComponents.count > 0 ?
                    integer(instructionComponents.first!) :
                    nil
                let instructionStatement = MemoryComponent.Statement(
                    represents: instruction,
                    operand: operand ?? 0)

                if instructionStatement.representsCompiled!.operand > 0 && operand == nil {
                    CLIStateController.terminate("Parse error (\(memoryComponent.name)): missing operand for instruction '\(instructionString)'")
                }

                memoryComponent.compiled[index] = instructionStatement
                continue
            }

            if let ascii = Expressions.ascii.match(firstComponent, group: 1) {
                for asciiCharacter in ascii.utf8 {
                    let asciiStatement = MemoryComponent.Statement(value: Int(asciiCharacter))
                    memoryComponent.compiled[index] = asciiStatement
                }
                continue
            }

            if let immediate = integer(firstComponent) {
                let immediateStatement = MemoryComponent.Statement(value: immediate)
                memoryComponent.compiled[index] = immediateStatement
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
