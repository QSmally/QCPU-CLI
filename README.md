
# QCPU CLI

> A CLI for compiling Q-code, assembling extended QCPU 2 assembly and emulating machine code.

## Commands
`qcpu <subcommand> <arguments>`

**Subcommands**
* `prebuild <path>` - processes macros and outputs assembly with only labels.
* `assemble <path>` - converts extended QCPU assembly into machine language.
* `documentate <path> --dest=path` - generates markdown documentation from the assembly tags.
* `emulate <path> --clock=int --burst=int` - executes QCPU machine code.
* `run <path> --clock=int --burst=int` - assembles and emulates extended QCPU assembly.
* `size <path>` - returns the size of the application.

**Arguments**
* `dest` - a path destination.
* `clock` - an interval in hertz.
* `burst` - a burst size of instructions to emulate.
