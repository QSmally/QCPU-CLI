//
//  ExecutionUnit.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

extension EmulatorStateController {
    func clockTick(executing statement: MemoryComponent.Statement, argument: Int) {
        switch statement.representsCompiled! {
            case .ppi: mmu.parameterStack.append(argument)
            case .ppl: accumulator = mmu.parameterStack.popLast() ?? 0
            case .ppk: accumulator = mmu.parameterStack.last ?? 0
            case .cpi: mmu.callStack.append(argument)
            case .cpl: accumulator = mmu.callStack.popLast() ?? 0
            case .cpa: modifiers.pointer = mmu.callStack.popLast() ?? 0
            case .nta: accumulator = ~accumulator
            case .pcm: modifiers.propagateCarry = true

            case .imm: writeback(statement.operand) { _ in argument }
            case .pps:
                let value = statement.operand == 0 ?
                    accumulator :
                    (registers[statement.operand] ?? 0)
                mmu.parameterStack.append(value)
            case .cps:
                let value = statement.operand == 0 ?
                    accumulator :
                    (registers[statement.operand] ?? 0)
                mmu.callStack.append(value)

            case .xch:
                let accumulatorCopy = accumulator
                accumulator = registers[statement.operand] ?? 0
                if statement.operand != 0 {
                    registers[statement.operand] = accumulatorCopy
                }
            case .rst:
                if statement.operand == 0 {
                    modifiers.forwarder = accumulator
                } else {
                    registers[statement.operand] = accumulator
                }
            case .ast: accumulator = registers[statement.operand] ?? 0

            case .inc: writeback(statement.operand) { $0 + 1 }
            case .dec: writeback(statement.operand) { $0 - 1 }
            case .neg: writeback(statement.operand) { ~$0 }
            case .rsh: writeback(statement.operand) { $0 >> 1 }
            case .add:
                accumulator = accumulator +
                    (registers[statement.operand] ?? 0) +
                    (modifiers.propagateCarry && flags[1]! ? 1 : 0)
                modifiers.propagateCarry = false
            case .sub: accumulator = accumulator - (registers[statement.operand] ?? 0)

            case .ior: accumulator = accumulator | (registers[statement.operand] ?? 0)
            case .and: accumulator = accumulator & (registers[statement.operand] ?? 0)
            case .xor: accumulator = accumulator ^ (registers[statement.operand] ?? 0)

            case .bsl: accumulator = accumulator << statement.operand
            case .bpl: accumulator = accumulator << (registers[statement.operand] ?? 0)
            case .bsr: accumulator = accumulator >> statement.operand
            case .bpr: accumulator = accumulator >> (registers[statement.operand] ?? 0)

            case .ent:
                mmu.applicationKernelCall(operand: statement.operand)
                return
            case .mmu:
                if mode == .kernel {
                    mmu.execute(instruction: statement.operand)
                    return
                }
            case .prf: dataCacheController(page: statement.operand)

            case .prt:
                let address = (registers[statement.operand] ?? 0) |
                    (statement.operand == 0 ? modifiers.forwarder : 0) |
                    modifiers.pointer |
                    argument

                if let port = ports[address: address] {
                    let instruction = argument - port.startAddress
                    port.execute(instruction: instruction)
                }

                modifiers.pointer = 0
                modifiers.forwarder = 0

            case .brh:
                if (flags[statement.operand] ?? false) {
                    let address = argument | modifiers.pointer
                    instructionCacheController(page: address >> 5)
                    nextCycle(address & 0b0001_1111)

                    modifiers.pointer = 0
                    modifiers.forwarder = 0
                    return
                }

                modifiers.pointer = 0
                modifiers.forwarder = 0
            case .jmp:
                let address = (registers[statement.operand] ?? 0) |
                    (statement.operand == 0 ? modifiers.forwarder : 0) |
                    modifiers.pointer |
                    argument

                instructionCacheController(page: address >> 5)
                nextCycle(address & 0b0001_1111)

                modifiers.pointer = 0
                modifiers.forwarder = 0
                return
            case .cal:
                let address = (registers[statement.operand] ?? 0) |
                    (statement.operand == 0 ? modifiers.forwarder : 0) |
                    modifiers.pointer |
                    argument

                let page = (instructionComponent.address?.page ?? 0) << 5
                mmu.callStack.append((page | line) + 1)

                instructionCacheController(page: address >> 5)
                nextCycle(address & 0b0001_1111)

                modifiers.pointer = 0
                modifiers.forwarder = 0
                return
            case .mst:
                let address = (registers[statement.operand] ?? 0) |
                    (statement.operand == 0 ? modifiers.forwarder : 0) |
                    modifiers.pointer |
                    argument
                let byte = MemoryComponent.Statement()
                    .transpile(value: accumulator)

                dataCacheController(page: address >> 5)
                dataComponent?.binary[address & 0b0001_1111] = byte
                mmu.dataCacheNeedsStore = true

                modifiers.pointer = 0
                modifiers.forwarder = 0

                if CLIStateController.flag(withId: "mwb") {
                    emulatorSuspendExecution(tag: "memory write")
                }
            case .mld:
                let address = (registers[statement.operand] ?? 0) |
                    (statement.operand == 0 ? modifiers.forwarder : 0) |
                    modifiers.pointer |
                    argument

                dataCacheController(page: address >> 5)
                accumulator = dataComponent?.binary[address & 0b0001_1111]?.value ?? 0

                modifiers.pointer = 0
                modifiers.forwarder = 0
            case .mli:
                let address = (registers[statement.operand] ?? 0) |
                    (statement.operand == 0 ? modifiers.forwarder : 0) |
                    modifiers.pointer |
                    argument

                dataCacheController(page: address >> 5)
                accumulator = dataComponent?.binary[address & 0b0001_1111]?.value ?? 0

                modifiers.pointer = 0
                modifiers.forwarder = 0

                if registers[statement.operand] ?? 0 != 0 {
                    let pointer = registers[statement.operand] ?? 0
                    registers[statement.operand] = pointer + 1
                }

            case .breakpoint:
                emulatorSuspendExecution(tag: "breakpoint")
        }

        nextCycle()
    }

    func updateConditionFlags(changedTo newAccumulator: Int) {
        flags[0] = newAccumulator > 255
        flags[1] = newAccumulator < 0
        flags[2] = newAccumulator == 0
        flags[3] = accumulator & 0x01 == 1
        flags[4] = !flags[0]!
        flags[5] = !flags[1]!
        flags[6] = !flags[2]!
        flags[7] = !flags[3]!
    }

    private func writeback(_ operand: Int, mutation: (Int) -> Int) {
        if operand == 0 {
            accumulator = mutation(accumulator)
        } else {
            accumulator = mutation(registers[operand] ?? 0)
            registers[operand] = accumulator
        }
    }

    private func emulatorSuspendExecution(tag: String) {
        clock?.suspend()
        updateUI()

        CLIStateController.newline("Breakpoint (\(tag)); press enter to resume")
        let _ = readLine(strippingNewline: true)
        clock?.resume()
    }

    internal func instructionCacheController(page address: Int) {
        if instructionComponent.address?.page ?? -1 != address || !mmu.instructionCacheValidated {
            let targetAddress = MemoryComponent.Address(
                segment: mmu.instructionSegment,
                page: address)

            // Swap new
            let loadedComponentCopy = memory
                .locate(address: targetAddress)?
                .clone()
            instructionComponent = loadedComponentCopy ?? MemoryComponent.empty(atAddress: targetAddress)
            mmu.instructionCacheValidated = true
        }
    }

    internal func dataCacheController(page address: Int) {
        if dataComponent?.address.page ?? -1 != address || !mmu.dataCacheValidated {
            let targetAddress = MemoryComponent.Address(
                segment: mmu.kernelDataContext ??
                    mmu.dataContext ??
                    mmu.instructionSegment,
                page: address)

            // Swapback
            if dataComponent != nil && mmu.dataCacheNeedsStore {
                memory.insert(memoryComponent: dataComponent.clone())
                mmu.dataCacheNeedsStore = false
            }

            // Swap new
            let loadedComponentCopy = memory
                .locate(address: targetAddress)?
                .clone()
            dataComponent = loadedComponentCopy ?? MemoryComponent.empty(atAddress: targetAddress)
            mmu.dataCacheValidated = true
        }
    }
}
