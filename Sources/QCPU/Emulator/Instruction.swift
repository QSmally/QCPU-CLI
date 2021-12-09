//
//  Instruction.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

import Dispatch

extension EmulatorStateController {
    func clockTick(executing statement: MemoryComponent.Statement, arguments: [Int]) {
        print("\(line - statement.representsCompiled.amountSecondaryBytes) \(statement.formatted)")

        switch statement.representsCompiled! {
            case .pst:
                print("output: \(accumulator)")
            case .cnd: condition = statement.operand
            case .imm: zeroTarget(statement.operand) { _ in arguments[0] }
            case .rst: registers[statement.operand] = accumulator
            case .ast: accumulator = registers[statement.operand] ?? 0
            case .inc: zeroTarget(statement.operand) { $0 + 1 }
            case .dec: zeroTarget(statement.operand) { $0 - 1 }
            case .neg: zeroTarget(statement.operand) { -$0 }
            case .rsh: zeroTarget(statement.operand) { $0 >> 1 }
            case .add: accumulator = accumulator + (registers[statement.operand] ?? 0)
            case .sub: accumulator = accumulator - (registers[statement.operand] ?? 0)
            case .ior: accumulator = accumulator | (registers[statement.operand] ?? 0)
            case .and: accumulator = accumulator & (registers[statement.operand] ?? 0)
            case .xor: accumulator = accumulator ^ (registers[statement.operand] ?? 0)
            case .imp: accumulator = ~accumulator | (registers[statement.operand] ?? 0)
            case .jmp:
                nextCycle(statement.operand)
                return
            default:
                break
        }

        nextCycle()
    }

    func updateConditionFlags() {}

    private func zeroTarget(_ operand: Int, mutation: (Int) -> Int) {
        if operand == 0 {
            accumulator = mutation(accumulator)
        } else {
            accumulator = mutation(registers[operand] ?? 0)
            registers[operand] = accumulator
        }
    }
}
