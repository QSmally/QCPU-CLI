
# QCPU CLI

> A CLI for compiling Q-code, assembling extended QCPU 2 assembly and emulating machine code.

## Commands
`qcpu <subcommand> <arguments>`

**Subcommands**
* `prebuild <path>` - processes macros and outputs assembly with only labels.
* `assemble <path>` - converts extended QCPU assembly into machine language.
* `documentate <path> --dest=path` - generates markdown documentation from the assembly tags.
* `run <path> --clock=int --burst=int --time=int --mwb` - assembles and emulates extended QCPU assembly.
* `size <path>` - returns the size of the application.

**Arguments**
* `path` / `dest` - a path destination.
* `clock` - an interval in hertz.
* `burst` - a burst size of instructions to emulate.
* `time` - milliseconds to spend on emulating before terminating.
* `mwb` - memory write breakpoint, halts clock at memory stores.
