//
//  Instruction.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

extension EmulatorStateController {
    func clockTick(executing statement: MemoryComponent.Statement, arguments: [Int]) {
        switch statement.representsCompiled! {
            case .dss:
                let addressTarget = MemoryComponent.Address(
                    segment: mmu.intermediateSegmentAddress,
                    page: arguments[0] | modifiers.pointer)
                modifiers._pointer = nil

                memory.removeAll { $0.address.equals(to: addressTarget, basedOn: .page) }
                memory.append(dataComponent.clone())
            case .dls:
                let addressTarget = MemoryComponent.Address(
                    segment: mmu.intermediateSegmentAddress,
                    page: arguments[0] | modifiers.pointer)
                modifiers._pointer = nil

                let loadedComponentCopy = memory
                    .first { $0.address.equals(to: addressTarget, basedOn: .page) }?
                    .clone()

                dataComponent = loadedComponentCopy ?? MemoryComponent.empty()
            case .spl:
                let addressTarget = MemoryComponent.Address(
                    upper: mmu.intermediateSegmentAddress,
                    lower: (arguments[optional: 0] ?? 0) | modifiers.pointer)
                modifiers._pointer = nil

                let loadedComponent = memory.first { $0.address.equals(to: addressTarget, basedOn: .page) }

                nextCycle(Int(addressTarget.line))
                instructionComponent = loadedComponent ?? MemoryComponent.empty()
                return
            case .nta: accumulator = ~accumulator
            case .pcm: modifiers.propagateCarry = true
            case .pst: mmu.store(at: statement.operand)
            case .pld: mmu.load(from: statement.operand)
            case .cpn:
                mmu.pin(at: statement.operand)
                return
            case .cnd: condition = statement.operand
            case .imm: zeroTarget(statement.operand) { _ in arguments[0] }
            case .rst: registers[statement.operand] = accumulator
            case .ast: accumulator = registers[statement.operand] ?? 0
            case .inc: zeroTarget(statement.operand) { $0 + 1 }
            case .dec: zeroTarget(statement.operand) { $0 - 1 }
            case .neg: zeroTarget(statement.operand) { -$0 }
            case .rsh: zeroTarget(statement.operand) { $0 >> 1 }
            case .add:
                accumulator = accumulator +
                    (registers[statement.operand] ?? 0) +
                    (modifiers.propagateCarry && flags[1]! ? 1 : 0)
                modifiers.propagateCarry = false
            case .sub:
                accumulator = accumulator -
                    (registers[statement.operand] ?? 0) -
                    (modifiers.propagateCarry && flags[1]! ? 1 : 0)
                modifiers.propagateCarry = false
            case .ent:
                mmu.parameters.append(arguments[0])
                mmu.applicationKernelCall()
                return
            case .pps: mmu.parameters.append(accumulator)
            case .ppl: accumulator = mmu.parameters.pop()
            case .cps:
                let address = (arguments[optional: 0] ?? 0) | modifiers.pointer
                mmu.addressCallStack.append(address)
                modifiers._pointer = nil
            case .cpl: accumulator = mmu.addressCallStack.pop()
            case .msa: mmu.mmuArgumentStack.append(arguments[0])
            case .mda: mmu.mmuArgumentStack.append(accumulator)
            case .mma: mmu.mmuArgumentStack.append(contentsOf: arguments)
            case .poi:
                modifiers._pointer = statement.operand == 0 ?
                    accumulator :
                    registers[statement.operand] ?? 0
            case .ior: accumulator = accumulator | (registers[statement.operand] ?? 0)
            case .and: accumulator = accumulator & (registers[statement.operand] ?? 0)
            case .xor: accumulator = accumulator ^ (registers[statement.operand] ?? 0)
            case .imp: accumulator = ~accumulator | (registers[statement.operand] ?? 0)
            case .jmp:
                if (flags[condition] ?? false) {
                    nextCycle(statement.operand | modifiers.pointer)
                    modifiers._pointer = nil
                    return
                }
            case .mst:
                let byte = MemoryComponent.Statement(value: accumulator)
                dataComponent.compiled[statement.operand | modifiers.pointer] = byte
                modifiers._pointer = nil
            case .mld:
                accumulator = dataComponent?.compiled[statement.operand | modifiers.pointer]?.value ?? 0
                modifiers._pointer = nil
            default:
                break
        }

        nextCycle()
    }

    func updateConditionFlags(changedTo newAccumulator: Int) {
        flags[0] = true
        flags[1] = newAccumulator > 255
        flags[2] = newAccumulator < 0
        flags[3] = newAccumulator == 0
        flags[4] = accumulator & 0x01 == 1
        flags[5] = !flags[1]!
        flags[6] = !flags[2]!
        flags[7] = !flags[3]!
    }

    private func zeroTarget(_ operand: Int, mutation: (Int) -> Int) {
        if operand == 0 {
            accumulator = mutation(accumulator)
        } else {
            accumulator = mutation(registers[operand] ?? 0)
            registers[operand] = accumulator
        }
    }
}
