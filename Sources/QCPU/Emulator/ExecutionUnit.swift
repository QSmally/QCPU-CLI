//
//  ExecutionUnit.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

extension EmulatorStateController {
    func clockTick(executing statement: MemoryComponent.Statement, arguments: [Int]) {
        switch statement.representsCompiled! {
            case .cpl: accumulator = mmu.callStack.popLast() ?? 0
            case .ppl: accumulator = mmu.parameterStack.popLast() ?? 0
            case .msa: mmu.mmuArgumentStack.append(arguments[0])
            case .mda: mmu.mmuArgumentStack.append(accumulator)
            case .nta: accumulator = ~accumulator
            case .dfu: modifiers.flags = false
            case .pcm: modifiers.propagateCarry = true
            // TODO: implement port addressing
            case .pst: outputStream.append(accumulator)
            case .pld: CLIStateController.newline("Port (\(statement.operand)): \(accumulator)")
            case .cpn:
                if mode == .kernel {
                    mmu.pin(at: statement.operand)
                    return
                } else {
                    CLIStateController.newline("Pin (\(statement.operand))")
                }
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
            case .ior: accumulator = accumulator | (registers[statement.operand] ?? 0)
            case .and: accumulator = accumulator & (registers[statement.operand] ?? 0)
            case .xor: accumulator = accumulator ^ (registers[statement.operand] ?? 0)
            case .imp: accumulator = ~accumulator & (registers[statement.operand] ?? 0)
            case .bsl: accumulator = accumulator << statement.operand
            case .bpl: accumulator = accumulator << (registers[statement.operand] ?? 0)
            case .bsr: accumulator = accumulator >> statement.operand
            case .bpr: accumulator = accumulator >> (registers[statement.operand] ?? 0)
            case .cps:
                let value = statement.operand == 0 ?
                    arguments[0] :
                    (registers[statement.operand] ?? 0)
                mmu.callStack.append(value)
            case .pps:
                let value = statement.operand == 0 ?
                    arguments[0] :
                    (registers[statement.operand] ?? 0)
                mmu.parameterStack.append(value)
            case .ent:
                mmu.parameterStack.append(statement.operand)
                mmu.applicationKernelCall()
                return
            case .jmp:
                let address = arguments[0] | (registers[statement.operand] ?? 0)
                instructionCacheController(page: address >> 5)
                nextCycle(address & 0x1F)
                return
            case .brh:
                if (flags[condition] ?? false) {
                    let address = arguments[0] | (registers[statement.operand] ?? 0)
                    instructionCacheController(page: address >> 5)
                    nextCycle(address & 0x1F)
                    return
                }
            case .mst:
                let address = arguments[0] | (registers[statement.operand] ?? 0)
                let byte = MemoryComponent.Statement(value: accumulator)
                dataCacheController(page: address >> 5)
                dataComponent?.compiled[address & 0x1F] = byte
            case .mld:
                let address = arguments[0] | (registers[statement.operand] ?? 0)
                dataCacheController(page: address >> 5)
                accumulator = dataComponent?.compiled[address]?.value ?? 0
            default:
                break
        }

        nextCycle()
    }

    func updateConditionFlags(changedTo newAccumulator: Int) {
        if modifiers.flags {
            flags[0] = true
            flags[1] = newAccumulator > 255
            flags[2] = newAccumulator < 0
            flags[3] = newAccumulator == 0
            flags[4] = accumulator & 0x01 == 1
            flags[5] = !flags[1]!
            flags[6] = !flags[2]!
            flags[7] = !flags[3]!
        } else {
            modifiers.flags = true
        }
    }

    private func zeroTarget(_ operand: Int, mutation: (Int) -> Int) {
        if operand == 0 {
            accumulator = mutation(accumulator)
        } else {
            accumulator = mutation(registers[operand] ?? 0)
            registers[operand] = accumulator
        }
    }

    private func instructionCacheController(page address: Int) {
        if instructionComponent.address?.page ?? -1 != address {
            let targetAddress = MemoryComponent.Address(
                segment: mmu.instructionSegment,
                page: address)

            // Swap new
            let loadedComponentCopy = memory
                .at(address: targetAddress)?
                .clone()
            instructionComponent = loadedComponentCopy ?? MemoryComponent.empty(atAddress: targetAddress)
        }
    }

    private func dataCacheController(page address: Int) {
        if dataComponent?.address.page ?? -1 != address {
            let targetAddress = MemoryComponent.Address(
                segment: mmu.dataContext ?? mmu.instructionSegment,
                page: address)

            // Swapback
            // TODO: emulate optional backswap if data was ever changed
            memory.insert(memoryComponent: dataComponent.clone())

            // Swap new
            let loadedComponentCopy = memory
                .at(address: targetAddress)?
                .clone()
            dataComponent = loadedComponentCopy ?? MemoryComponent.empty(atAddress: targetAddress)
        }
    }
}