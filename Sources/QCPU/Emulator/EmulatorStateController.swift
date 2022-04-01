//
//  EmulatorStateController.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 06/12/2021.
//

import Foundation

final class EmulatorStateController {

    // State
    var line = 0
    var cycles: UInt = 0
    var mode: ExecutionContext = .kernel

    var modifiers = Modifiers()
    var immediateStatement: MemoryComponent.Statement!

    // Clock and UI
    var defaults: EmulatorDefaults
    var clock: DispatchSourceTimer?
    let instructionQueue = DispatchQueue(
        label: "eu.qbot.qcpu-cli.clock",
        qos: .userInitiated)
    var renderedStream = String()

    // Memory controller
    lazy var mmu = MMU(emulator: self)

    var memory: [MemoryComponent]
    var instructionComponent: MemoryComponent!
    var dataComponent: MemoryComponent!

    // CPU memory
    var accumulator = 0 { willSet { updateConditionFlags(changedTo: newValue) } }

    var flags = [Int: Bool]()
    var registers = [Int: Int]()
    var outputStream = [String]()

    lazy var ports: [CountableClosedRange<Int>: Device] = {
        var startAddress = 0

        return (defaults.ports ?? []).reduce(into: [CountableClosedRange<Int>: Device]()) { (map, port) in
            let portAddress = port.address ?? startAddress
            let device = port.generateClass(emulator: self, startAddress: portAddress)
            let endClosedAddress = portAddress + device.instructionSize - 1

            startAddress = endClosedAddress + 1
            map[portAddress...endClosedAddress] = device
        }
    }()

    enum ExecutionContext {
        case application,
             kernel,
             halted
    }

    class Modifiers {
        var pointer = 0
        var propagateCarry = false
    }

    init(defaults: EmulatorDefaults, memoryComponents: [MemoryComponent]) {
        self.defaults = defaults
        self.memory = memoryComponents
    }

    func startClockTimer(withSpeed speed: Double?, burstSize: Int = 4096) {
        guard let entryComponent = memory.locate(address: MemoryComponent.Address(segment: 0, page: 0)) else {
            CLIStateController.terminate("Fatal error: no program entry (0, 0)")
        }

        // Initialisation
        for register in 1...7 {
            registers[register] = 0
        }

        accumulator = 0
        instructionComponent = entryComponent
        updateUI()

        // Clock
        if let speed = speed {
            clock = DispatchSource.makeTimerSource(queue: instructionQueue)
            clock?.setEventHandler(handler: clockTickMask)
            clock?.schedule(deadline: .now() + 0.25, repeating: 1 / speed)

            clock?.resume()
            initialiseClock()
        } else {
            let startTime = DispatchTime
                .now()
                .uptimeNanoseconds
            let maximummTimeString = CLIStateController.argument(withId: "time")
            let maximumTime = maximummTimeString != nil ?
                (UInt64(maximummTimeString!) ?? UInt64(25)) * 1_000_000 :
                UInt64(defaults.maxTime ?? 25_000_000)

            while DispatchTime.now().uptimeNanoseconds - startTime < maximumTime {
                for _ in 1...burstSize { clockTickMask() }
                updateUI()
            }

            CLIStateController.terminate("Fatal error: ran out of time (modify this behaviour with --time=int)")
        }
    }

    func clockTickMask() {
        guard let statement = instructionComponent.binary[line] else {
            mode = .halted
            updateUI()
            CLIStateController.terminate()
        }

        if let immediateStatement = immediateStatement {
            clockTick(
                executing: immediateStatement,
                argument: statement.value)
            self.immediateStatement = nil
        } else {
            guard let compiledStatement = statement.representsCompiled else {
                CLIStateController.terminate("Runtime error: byte '\(statement.formatted)' (line \(line)) isn't a compiled instruction")
            }

            if compiledStatement.hasSecondaryByte {
                immediateStatement = statement
                nextCycle()
                return
            }

            clockTick(executing: statement, argument: 0)
        }
    }

    func initialiseClock() {
        if let index = ports.firstIndex(where: { $1.profile.type == .terminal }) {
            while true {
                let character = Int(FileHandle.getch())
                let interruptTerminal = ports[index].value as! TerminalDevice
                interruptTerminal.characters.append(character)
            }
        } else {
            RunLoop.main.run()
        }
    }

    func nextCycle(_ line: Int? = nil) {
        self.line = line ?? self.line + 1
        cycles += 1

        if self.line >> 5 != 0 {
            instructionCacheController(page: instructionComponent.address.page + 1)
            self.line = 0
        }

        if clock != nil {
            updateUI()
        }
    }
}
